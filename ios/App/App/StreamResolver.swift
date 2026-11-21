import Foundation

// MARK: - Models

struct StreamSource {
    let url: URL
    let referer: String
    let origin: String?
    let userAgent: String
    let serverName: String
    let category: String
    let isHLS: Bool
}

enum StreamResolverError: LocalizedError {
    case invalidURL
    case noPlayableStreamFound(String)
    case networkError(String)
    case parsingError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid stream request URL."
        case .noPlayableStreamFound(let srv):
            return "No direct stream found on \(srv)."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .parsingError(let msg):
            return "Parsing error: \(msg)"
        case .cancelled:
            return "Stream resolution cancelled."
        }
    }
}

// MARK: - Stream Resolver

final class StreamResolver {

    static let shared = StreamResolver()

    private let defaultUserAgent = "Mozilla/5.0 (iPad; CPU OS 12_5_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    private let fallbackUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private var activeDataTask: URLSessionDataTask?
    private var isCancelled = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 14.0
        config.timeoutIntervalForResource = 25.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private init() {}

    func cancel() {
        isCancelled = true
        activeDataTask?.cancel()
        activeDataTask = nil
    }

    // MARK: - Multi-Server Cascade Resolution

    func resolveStream(
        episodeId: String,
        episodeNum: Int,
        slug: String,
        apiBase: String,
        preferredServer: String,
        category: String,
        statusUpdate: @escaping (String) -> Void,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        cancel()
        isCancelled = false

        // Build candidate list in prioritized order
        var candidates: [(server: String, cat: String, sourceKind: String)] = []

        let cleanPrefServer = preferredServer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCat = (category.lowercased() == "dub") ? "dub" : "sub"
        let altCat = (cleanCat == "sub") ? "dub" : "sub"

        // 1. Preferred server & requested category
        let primaryServer = cleanPrefServer.isEmpty ? "hd-1" : cleanPrefServer
        candidates.append((server: primaryServer, cat: cleanCat, sourceKind: "primary"))

        // 2. Other standard servers on primary category
        let standardServers = ["hd-1", "hd-2", "megacloud"]
        for srv in standardServers {
            if srv != primaryServer {
                candidates.append((server: srv, cat: cleanCat, sourceKind: "primary"))
            }
        }

        // 3. Alternate category (dub/sub) fallback on primary server
        candidates.append((server: primaryServer, cat: altCat, sourceKind: "primary"))

        // 4. Secondary working anime sources (Consumet / Zoro / Gogoanime endpoints)
        candidates.append((server: "consumet-zoro", cat: cleanCat, sourceKind: "consumet-zoro"))
        candidates.append((server: "consumet-gogo", cat: cleanCat, sourceKind: "consumet-gogo"))
        candidates.append((server: "allanime", cat: cleanCat, sourceKind: "allanime"))

        executeCascade(
            candidates: candidates,
            index: 0,
            episodeId: episodeId,
            episodeNum: episodeNum,
            slug: slug,
            apiBase: apiBase,
            statusUpdate: statusUpdate,
            completion: completion
        )
    }

    private func executeCascade(
        candidates: [(server: String, cat: String, sourceKind: String)],
        index: Int,
        episodeId: String,
        episodeNum: Int,
        slug: String,
        apiBase: String,
        statusUpdate: @escaping (String) -> Void,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        guard !isCancelled else {
            completion(.failure(StreamResolverError.cancelled))
            return
        }

        guard index < candidates.count else {
            completion(.failure(StreamResolverError.noPlayableStreamFound("all servers")))
            return
        }

        let current = candidates[index]
        let serverTitle = current.server.uppercased()
        let catTitle = current.cat.uppercased()

        DispatchQueue.main.async {
            statusUpdate("Looking for a direct stream (\(serverTitle) - \(catTitle))...")
        }

        let nextStep: () -> Void = { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            self.executeCascade(
                candidates: candidates,
                index: index + 1,
                episodeId: episodeId,
                episodeNum: episodeNum,
                slug: slug,
                apiBase: apiBase,
                statusUpdate: statusUpdate,
                completion: completion
            )
        }

        switch current.sourceKind {
        case "primary":
            resolvePrimaryApi(
                apiBase: apiBase,
                episodeId: episodeId,
                server: current.server,
                category: current.cat
            ) { [weak self] result in
                guard let self = self, !self.isCancelled else { return }
                switch result {
                case .success(let source):
                    completion(.success(source))
                case .failure(let err):
                    print("Primary API (\(serverTitle)) failed: \(err.localizedDescription)")
                    nextStep()
                }
            }

        case "consumet-zoro":
            resolveConsumetZoro(
                episodeId: episodeId,
                server: current.server
            ) { [weak self] result in
                guard let self = self, !self.isCancelled else { return }
                switch result {
                case .success(let source):
                    completion(.success(source))
                case .failure:
                    nextStep()
                }
            }

        case "consumet-gogo":
            resolveConsumetGogo(
                slug: slug,
                episodeNum: episodeNum
            ) { [weak self] result in
                guard let self = self, !self.isCancelled else { return }
                switch result {
                case .success(let source):
                    completion(.success(source))
                case .failure:
                    nextStep()
                }
            }

        case "allanime":
            resolveAllAnime(
                slug: slug,
                episodeNum: episodeNum
            ) { [weak self] result in
                guard let self = self, !self.isCancelled else { return }
                switch result {
                case .success(let source):
                    completion(.success(source))
                case .failure:
                    nextStep()
                }
            }

        default:
            nextStep()
        }
    }

    // MARK: - Primary HiAnime / Aniwatch API Resolver

    private func resolvePrimaryApi(
        apiBase: String,
        episodeId: String,
        server: String,
        category: String,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else {
            completion(.failure(StreamResolverError.networkError("No primary API configured")))
            return
        }

        // Clean episodeId if it contains query parameters (e.g. ep=123)
        var cleanEpId = episodeId
        if cleanEpId.contains("ep=") {
            let parts = cleanEpId.components(separatedBy: "ep=")
            if parts.count > 1 {
                cleanEpId = parts[1].components(separatedBy: "&")[0].components(separatedBy: "#")[0]
            }
        }

        guard let encodedEp = cleanEpId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedServer = server.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedCat = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/anime/episode-srcs?id=\(encodedEp)&server=\(encodedServer)&category=\(encodedCat)") else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        activeDataTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, !self.isCancelled else {
                completion(.failure(StreamResolverError.cancelled))
                return
            }

            if let error = error {
                completion(.failure(StreamResolverError.networkError(error.localizedDescription)))
                return
            }

            guard let data = data,
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                  let root = jsonObject as? [String: Any] else {
                completion(.failure(StreamResolverError.parsingError("Invalid JSON from episode-srcs")))
                return
            }

            let dataObj = (root["data"] as? [String: Any]) ?? root

            // 1. Check direct raw sources
            if let sources = dataObj["sources"] as? [[String: Any]], !sources.isEmpty {
                for src in sources {
                    if let streamUrlStr = (src["url"] as? String) ?? (src["file"] as? String),
                       let streamUrl = URL(string: streamUrlStr) {
                        let isHls = (src["type"] as? String)?.lowercased() == "hls" || streamUrlStr.contains(".m3u8")

                        var resolvedReferer = "https://megacloud.tv/"
                        var resolvedOrigin: String? = "https://megacloud.tv"
                        var resolvedUA = self.defaultUserAgent

                        if let headers = dataObj["headers"] as? [String: Any] {
                            if let ref = headers["Referer"] as? String, !ref.isEmpty {
                                resolvedReferer = ref
                            }
                            if let orig = headers["Origin"] as? String, !orig.isEmpty {
                                resolvedOrigin = orig
                            }
                            if let ua = headers["User-Agent"] as? String, !ua.isEmpty {
                                resolvedUA = ua
                            }
                        }

                        let source = StreamSource(
                            url: streamUrl,
                            referer: resolvedReferer,
                            origin: resolvedOrigin,
                            userAgent: resolvedUA,
                            serverName: server,
                            category: category,
                            isHLS: isHls
                        )
                        completion(.success(source))
                        return
                    }
                }
            }

            // 2. Check if embed URL is provided in headers.Referer or iframeUrl
            var embedUrlStr: String? = nil
            if let headers = dataObj["headers"] as? [String: Any], let ref = headers["Referer"] as? String {
                embedUrlStr = ref
            } else if let iframe = dataObj["iframeUrl"] as? String {
                embedUrlStr = iframe
            }

            if let embedStr = embedUrlStr, !embedStr.isEmpty {
                self.extractStreamFromEmbed(embedUrlString: embedStr, server: server, category: category, completion: completion)
                return
            }

            completion(.failure(StreamResolverError.noPlayableStreamFound(server)))
        }
        activeDataTask?.resume()
    }

    // MARK: - Embed URL Extractor (Megacloud / RapidCloud / Zoro Native Scraper)

    private func extractStreamFromEmbed(
        embedUrlString: String,
        server: String,
        category: String,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        guard let embedUrl = URL(string: embedUrlString),
              let host = embedUrl.host else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        // Try extracting source ID for Megacloud / RapidCloud / RabbitStream
        // Format: /embed-2/e-1/{id}?k=1 or /e-1/{id}
        var sourceId: String? = nil
        let regexPatterns = [
            "e-1/([a-zA-Z0-9_-]+)",
            "embed-[0-9]+/([a-zA-Z0-9_-]+)",
            "id=([a-zA-Z0-9_-]+)"
        ]

        for pat in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: []),
               let match = regex.firstMatch(in: embedUrlString, options: [], range: NSRange(location: 0, length: embedUrlString.utf16.count)) {
                if let r = Range(match.range(at: 1), in: embedUrlString) {
                    sourceId = String(embedUrlString[r])
                    break
                }
            }
        }

        if let id = sourceId, !id.isEmpty {
            let ajaxUrlString = "https://\(host)/embed-2/ajax/e-1/getSources?id=\(id)"
            if let ajaxUrl = URL(string: ajaxUrlString) {
                var req = URLRequest(url: ajaxUrl)
                req.httpMethod = "GET"
                req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                req.setValue(embedUrlString, forHTTPHeaderField: "Referer")
                req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")

                let task = session.dataTask(with: req) { [weak self] data, _, _ in
                    guard let self = self, !self.isCancelled else { return }

                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        if let sources = json["sources"] as? [[String: Any]], !sources.isEmpty {
                            for src in sources {
                                if let file = (src["file"] as? String) ?? (src["url"] as? String),
                                   let directURL = URL(string: file) {
                                    let isHls = file.contains(".m3u8")
                                    let s = StreamSource(
                                        url: directURL,
                                        referer: "https://\(host)/",
                                        origin: "https://\(host)",
                                        userAgent: self.defaultUserAgent,
                                        serverName: server,
                                        category: category,
                                        isHLS: isHls
                                    )
                                    completion(.success(s))
                                    return
                                }
                            }
                        }
                    }

                    // If AJAX getSources failed, fallback to scrape embed HTML
                    self.scrapeEmbedHtml(embedUrl: embedUrl, server: server, category: category, completion: completion)
                }
                task.resume()
                return
            }
        }

        // Direct HTML scrape fallback
        scrapeEmbedHtml(embedUrl: embedUrl, server: server, category: category, completion: completion)
    }

    private func scrapeEmbedHtml(
        embedUrl: URL,
        server: String,
        category: String,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        var req = URLRequest(url: embedUrl)
        req.httpMethod = "GET"
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self, !self.isCancelled else { return }

            if let error = error {
                completion(.failure(StreamResolverError.networkError(error.localizedDescription)))
                return
            }

            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(StreamResolverError.parsingError("Could not read embed HTML")))
                return
            }

            // Regex for direct .m3u8 stream link in embed source
            let m3u8Pattern = "(https?://[^\"'\\s<>]+\\.(?:m3u8|mp4)[^\"'\\s<>]*)"
            if let regex = try? NSRegularExpression(pattern: m3u8Pattern, options: []),
               let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count)),
               let r = Range(match.range(at: 1), in: html) {
                let foundUrlString = String(html[r]).replacingOccurrences(of: "\\/", with: "/")
                if let directURL = URL(string: foundUrlString) {
                    let host = embedUrl.host ?? "megacloud.tv"
                    let source = StreamSource(
                        url: directURL,
                        referer: "https://\(host)/",
                        origin: "https://\(host)",
                        userAgent: self.defaultUserAgent,
                        serverName: server,
                        category: category,
                        isHLS: foundUrlString.contains(".m3u8")
                    )
                    completion(.success(source))
                    return
                }
            }

            completion(.failure(StreamResolverError.noPlayableStreamFound(server)))
        }
        task.resume()
    }

    // MARK: - Secondary Working Anime Source: Consumet Zoro / HiAnime

    private func resolveConsumetZoro(
        episodeId: String,
        server: String,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        guard let encodedId = episodeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        let endpoints = [
            "https://api.consumet.org/anime/zoro/watch?episodeId=\(encodedId)",
            "https://consumet-api.herokuapp.com/anime/zoro/watch?episodeId=\(encodedId)"
        ]

        tryConsumetEndpoints(endpoints: endpoints, index: 0, serverName: "Consumet-Zoro", completion: completion)
    }

    // MARK: - Secondary Working Anime Source: Consumet Gogoanime

    private func resolveConsumetGogo(
        slug: String,
        episodeNum: Int,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        let cleanSlug = slug.replacingOccurrences(of: " ", with: "-").lowercased()
        let gogoEpId = "\(cleanSlug)-episode-\(episodeNum)"
        guard let encodedId = gogoEpId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        let endpoints = [
            "https://api.consumet.org/anime/gogoanime/watch/\(encodedId)",
            "https://consumet-api.herokuapp.com/anime/gogoanime/watch/\(encodedId)"
        ]

        tryConsumetEndpoints(endpoints: endpoints, index: 0, serverName: "Consumet-Gogo", completion: completion)
    }

    private func tryConsumetEndpoints(
        endpoints: [String],
        index: Int,
        serverName: String,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        guard index < endpoints.count else {
            completion(.failure(StreamResolverError.noPlayableStreamFound(serverName)))
            return
        }

        guard let url = URL(string: endpoints[index]) else {
            tryConsumetEndpoints(endpoints: endpoints, index: index + 1, serverName: serverName, completion: completion)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self, !self.isCancelled else { return }

            if error == nil, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let sources = json["sources"] as? [[String: Any]], !sources.isEmpty {

                for src in sources {
                    if let urlStr = (src["url"] as? String) ?? (src["file"] as? String),
                       let directURL = URL(string: urlStr) {
                        var referer = "https://s3taku.com"
                        if let headers = json["headers"] as? [String: Any],
                           let ref = headers["Referer"] as? String, !ref.isEmpty {
                            referer = ref
                        }

                        let s = StreamSource(
                            url: directURL,
                            referer: referer,
                            origin: nil,
                            userAgent: self.defaultUserAgent,
                            serverName: serverName,
                            category: "sub",
                            isHLS: urlStr.contains(".m3u8")
                        )
                        completion(.success(s))
                        return
                    }
                }
            }

            self.tryConsumetEndpoints(endpoints: endpoints, index: index + 1, serverName: serverName, completion: completion)
        }
        task.resume()
    }

    // MARK: - Secondary Working Anime Source: AllAnime JSON

    private func resolveAllAnime(
        slug: String,
        episodeNum: Int,
        completion: @escaping (Result<StreamSource, Error>) -> Void
    ) {
        let cleanSlug = slug.replacingOccurrences(of: " ", with: "-").lowercased()
        let allAnimeId = "\(cleanSlug)"
        guard let encoded = allAnimeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        let urlString = "https://api.consumet.org/anime/allanime/watch?episodeId=\(encoded)&episode=\(episodeNum)"
        guard let url = URL(string: urlString) else {
            completion(.failure(StreamResolverError.invalidURL))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: req) { [weak self] data, _, error in
            guard let self = self, !self.isCancelled else { return }

            if error == nil, let data = data,
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let sources = json["sources"] as? [[String: Any]], !sources.isEmpty {

                for src in sources {
                    if let urlStr = (src["url"] as? String) ?? (src["file"] as? String),
                       let directURL = URL(string: urlStr) {
                        let s = StreamSource(
                            url: directURL,
                            referer: "https://allanime.to",
                            origin: "https://allanime.to",
                            userAgent: self.defaultUserAgent ?? "",
                            serverName: "AllAnime",
                            category: "sub",
                            isHLS: urlStr.contains(".m3u8")
                        )
                        completion(.success(s))
                        return
                    }
                }
            }

            completion(.failure(StreamResolverError.noPlayableStreamFound("AllAnime")))
        }
        task.resume()
    }
}
