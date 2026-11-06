import Foundation
import Hummingbird
import HTTPTypes

/// Port of `main/src/proxy.ts`: forwards `/proxy/<host>/<path>` to `https://<host>/<path>`
/// for an allowlist of hosts. No cookie bridge to WKWebView yet (planned for M5).
public struct HttpProxy: Sendable {
    /// `PROXY_HOSTS` from `proxy.ts:5-19`. A contract test will keep this in sync with upstream.
    public static let allowedHosts: Set<String> = [
        "www.pathofexile.com",
        "ru.pathofexile.com",
        "pathofexile.tw",
        "poe.kakaogames.com",
        "jp.pathofexile.com",
        "de.pathofexile.com",
        "es.pathofexile.com",
        "br.pathofexile.com",
        "fr.pathofexile.com",
        "poe.ninja",
        "www.poeprices.info",
        "api.exiledexchange2.dev",
    ]

    /// Request headers never forwarded. Upstream strips `sec-*`, host, origin, content-length
    /// (`proxy.ts:33-43`). We also drop hop-by-hop headers and accept-encoding, so URLSession
    /// negotiates only encodings it can decode (the browser may offer zstd).
    static func shouldForwardRequestHeader(_ lowercasedName: String) -> Bool {
        if lowercasedName.hasPrefix("sec-") { return false }
        return ![
            "host", "origin", "content-length", "accept-encoding", "connection",
            "keep-alive", "transfer-encoding", "te", "upgrade", "user-agent", "cookie",
        ].contains(lowercasedName)
    }

    /// Response headers never passed back. URLSession already decompressed the body, so the
    /// encoding and length headers would be wrong (`proxy.ts:58` drops content-encoding only).
    static func shouldForwardResponseHeader(_ lowercasedName: String) -> Bool {
        ![
            "content-encoding", "content-length", "transfer-encoding", "connection",
            "keep-alive", "set-cookie",
        ].contains(lowercasedName)
    }

    /// Splits `/proxy/<host>/<rest>` into the host and the target URL. Nil if not allowlisted.
    static func target(forRequestURI uri: String) -> (host: String, url: URL)? {
        guard uri.hasPrefix("/proxy/") else { return nil }
        let rest = String(uri.dropFirst("/proxy/".count))
        let host = String(rest.prefix { $0 != "/" && $0 != "?" })
        guard allowedHosts.contains(host), let url = URL(string: "https://" + rest) else { return nil }
        return (host, url)
    }

    let session: URLSession
    let userAgent: String
    let log: @Sendable (String) async -> Void
    /// Per-request trace for development (stdout only, never broadcast to the renderer).
    let trace: @Sendable (String) -> Void

    public init(
        userAgent: String,
        log: @escaping @Sendable (String) async -> Void,
        trace: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.trace = trace
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true // upstream: useSessionCookies (proxy.ts:52)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
        self.log = log
    }

    public func handle(_ request: Request, context: some RequestContext) async throws -> Response {
        guard let target = Self.target(forRequestURI: request.uri.description) else {
            // Upstream destroys the connection (`proxy.ts:31`); a 403 is the closest HTTP equivalent.
            return Response(status: .forbidden)
        }

        var urlRequest = URLRequest(url: target.url)
        urlRequest.httpMethod = request.method.rawValue
        for field in request.headers where Self.shouldForwardRequestHeader(field.name.canonicalName) {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body = try await request.body.collect(upTo: 16_000_000)
        if body.readableBytes > 0 {
            urlRequest.httpBody = Data(buffer: body)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                return Response(status: .badGateway)
            }
            trace("\(request.method.rawValue) \(target.url.absoluteString) → \(http.statusCode), \(data.count) bytes")
            var headers = HTTPFields()
            for (key, value) in http.allHeaderFields {
                guard let name = key as? String, let value = value as? String,
                      Self.shouldForwardResponseHeader(name.lowercased()),
                      let fieldName = HTTPField.Name(name)
                else { continue }
                headers.append(HTTPField(name: fieldName, value: value))
            }
            return Response(
                status: HTTPResponse.Status(code: http.statusCode),
                headers: headers,
                body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
            )
        } catch {
            await log("error [proxy] \(error.localizedDescription) (\(target.host))")
            return Response(status: .badGateway)
        }
    }
}
