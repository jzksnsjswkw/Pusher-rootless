import Foundation

/// WeChat Work (企业微信) application messages.
///
/// Unlike the other services, this one needs an `access_token` before it can
/// build a request, so it overrides the asynchronous request builder. Tokens
/// are cached per `corpid|corpsecret` and refreshed through a single-flight
/// fetch, so a burst of notifications results in one `gettoken` call rather
/// than one per notification.
public enum WechatService: PushService {
    public static let serviceName = "Wechat"
    static let pushURLBase = "https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token="
    static let tokenURL = "https://qyapi.weixin.qq.com/cgi-bin/gettoken"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURLBase
    }

    // MARK: - Request building

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        // Reached only if the async path is bypassed; without a token there is
        // no usable URL, so fail rather than sending an empty one.
        nil
    }

    public static func request(
        context: BulletinContext,
        config: ServiceConfig,
        completion: @escaping (PushRequest?) -> Void
    ) {
        let touser = config.raw.string(PrefKey.touser, default: "")
        let infoDict: [String: Any] = [
            "touser": touser.isEmpty ? "@all" : touser,
            "msgtype": "text",
            "agentid": config.raw.int(PrefKey.agentID),
            "text": ["content": "\(context.displayTitle)\n\(context.displayMessage)"],
            "safe": 0,
        ]

        let corpid = config.raw.string(PrefKey.corpid, default: "")
        let corpsecret = config.raw.string(PrefKey.corpsecret, default: "")
        guard !corpid.isEmpty, !corpsecret.isEmpty else {
            // Missing credentials: abort rather than sending a request with an
            // empty URL. The caller treats nil as "failed to build request".
            completion(nil)
            return
        }

        let cacheKey = WechatTokenCache.key(corpid: corpid, corpsecret: corpsecret)
        if let token = WechatTokenCache.cachedToken(forKey: cacheKey) {
            completion(pushRequest(token: token, infoDict: infoDict,
                                   cacheKey: cacheKey, corpid: corpid, corpsecret: corpsecret))
            return
        }

        WechatTokenCache.fetch(corpid: corpid, corpsecret: corpsecret, invalidating: nil) { token in
            guard let token, !token.isEmpty else {
                // Failed to obtain an access token (network error or invalid
                // credentials). Abort rather than firing a request with an empty
                // token that is guaranteed to fail server-side.
                completion(nil)
                return
            }
            // The fetch already cached the token before invoking this closure.
            completion(pushRequest(token: token, infoDict: infoDict,
                                   cacheKey: cacheKey, corpid: corpid, corpsecret: corpsecret))
        }
    }

    private static func pushRequest(
        token: String,
        infoDict: [String: Any],
        cacheKey: String,
        corpid: String,
        corpsecret: String
    ) -> PushRequest {
        let encodedToken = token.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? token
        let url = pushURLBase + encodedToken

        let request = PushRequest(urlString: url, infoDict: infoDict)
        request.logInfoDict = logInfoDict(infoDict)
        request.state["token"] = token
        request.resendHandler = resendHandler(
            cacheKey: cacheKey, corpid: corpid, corpsecret: corpsecret
        )
        return request
    }

    // MARK: - Token expiry handling

    /// WeChat error codes meaning the access token must be refreshed.
    private static let invalidTokenCode = 40014
    private static let expiredTokenCode = 42001

    /// Inspects the response and, when WeChat rejected the token, refreshes it
    /// and resends.
    ///
    /// This runs on every response, so a non-zero error code that does *not*
    /// mean "expired" has to be surfaced as a failure here — otherwise the
    /// sender's generic "HTTP response = success" path would report a rejected
    /// message as delivered.
    private static func resendHandler(
        cacheKey: String,
        corpid: String,
        corpsecret: String
    ) -> ResendHandler {
        { request, _, data, error, completion in
            guard error == nil, let data else {
                completion(nil, false)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                request.failureReason = "WeChat returned an invalid/non-JSON response"
                completion(nil, true)
                return
            }

            // WeChat always returns `errcode` as a number here. A missing or
            // null value must not read as 0 (which would log a malformed
            // response as success), so its absence is a failure.
            guard let errcode = (json["errcode"] as? NSNumber)?.intValue else {
                request.failureReason = "WeChat returned a response without a valid errcode"
                completion(nil, true)
                return
            }
            let errmsg = json["errmsg"] as? String ?? ""

            let tokenExpired = errcode == invalidTokenCode || errcode == expiredTokenCode
            guard tokenExpired else {
                if errcode != 0 {
                    request.failureReason = "WeChat send failed (errcode=\(errcode), errmsg=\(errmsg))"
                    completion(nil, true)
                } else {
                    completion(nil, false)
                }
                return
            }

            // Refresh the token. The rejected token is passed along so the
            // cache is only invalidated when it still holds *that* token; if a
            // concurrent refresh already stored a newer one, it is reused.
            let rejectedToken = request.state["token"] as? String
            WechatTokenCache.fetch(corpid: corpid, corpsecret: corpsecret,
                                   invalidating: rejectedToken) { newToken in
                guard let newToken, !newToken.isEmpty else {
                    request.failureReason = "WeChat access_token invalid (errcode=\(errcode), "
                        + "errmsg=\(errmsg)); refresh failed"
                    // Do not abort the send on a single failed gettoken: the
                    // failure is usually a transient network hiccup and the
                    // sender still has retry budget, so resend the original
                    // request and let the next attempt re-drive the refresh.
                    completion(request, false)
                    return
                }
                let newRequest = pushRequest(
                    token: newToken, infoDict: request.infoDict, cacheKey: cacheKey,
                    corpid: corpid, corpsecret: corpsecret
                )
                completion(newRequest, false)
            }
        }
    }

    public static func extraPrefs(_ servicePrefs: Prefs) -> [String: Any]? {
        [
            PrefKey.corpid: servicePrefs.string(PrefKey.corpid, default: ""),
            PrefKey.corpsecret: servicePrefs.string(PrefKey.corpsecret, default: ""),
            PrefKey.agentID: servicePrefs.int(PrefKey.agentID),
            PrefKey.touser: servicePrefs.string(PrefKey.touser, default: ""),
        ]
    }

    public static func extraCustomAppPrefs(_ appPrefs: Prefs) -> [String: Any]? {
        // Only the recipient differs per app; the credentials stay service-wide.
        [PrefKey.touser: appPrefs.string(PrefKey.touser, default: "")]
    }
}

/// The WeChat access-token cache.
///
/// Tokens live for roughly 7200 seconds. Caching them avoids re-requesting (and
/// risking rate-limits) on every notification, and keeps a failed `gettoken`
/// from poisoning the retry path with an empty token.
enum WechatTokenCache {
    private struct Entry {
        let token: String
        let expiresAt: Date
        /// Stored verbatim so a cache hit can report the same `expires_in` that
        /// a network fetch would.
        let expiresIn: Int
    }

    private static var cache: [String: Entry] = [:]
    /// In-flight fetches per cache key, so concurrent callers join one request.
    private static var pending: [String: [(String?) -> Void]] = [:]
    private static let lock = NSLock()

    static func key(corpid: String, corpsecret: String) -> String { "\(corpid)|\(corpsecret)" }

    /// A cached token, or `nil` when there is none or it has expired.
    static func cachedToken(forKey key: String, invalidating rejectedToken: String? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        guard entry.expiresAt.timeIntervalSinceNow > 0 else {
            cache.removeValue(forKey: key)
            return nil
        }
        // When refreshing, only discard the cache if it still holds the token
        // that was rejected; if another fetch already stored a newer token, that
        // one is used instead of starting another fetch.
        if let rejectedToken, entry.token == rejectedToken {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.token
    }

    /// Fetches a token, joining an in-flight request for the same credentials
    /// when there is one.
    static func fetch(
        corpid: String,
        corpsecret: String,
        invalidating rejectedToken: String?,
        completion: @escaping (String?) -> Void
    ) {
        let key = key(corpid: corpid, corpsecret: corpsecret)

        // The cache lookup, invalidation and single-flight registration must
        // happen in one critical section: a fetch completing between "cache
        // miss" and "register pending" would otherwise cause a duplicate
        // gettoken, and a delayed refresh could delete a token a concurrent
        // fetch had just written.
        lock.lock()
        if let token = cachedTokenLocked(forKey: key, invalidating: rejectedToken) {
            lock.unlock()
            completion(token)
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            lock.unlock()
            // Joined an in-flight fetch; its completion notifies this caller.
            return
        }
        pending[key] = [completion]
        lock.unlock()

        performFetch(corpid: corpid, corpsecret: corpsecret, key: key)
    }

    private static func cachedTokenLocked(forKey key: String, invalidating rejectedToken: String?) -> String? {
        guard let entry = cache[key] else { return nil }
        guard entry.expiresAt.timeIntervalSinceNow > 0 else {
            cache.removeValue(forKey: key)
            return nil
        }
        if let rejectedToken, entry.token == rejectedToken {
            cache.removeValue(forKey: key)
            return nil
        }
        return entry.token
    }

    private static func performFetch(corpid: String, corpsecret: String, key: String) {
        var components = URLComponents(string: WechatService.tokenURL)
        components?.queryItems = [
            URLQueryItem(name: "corpid", value: corpid),
            URLQueryItem(name: "corpsecret", value: corpsecret),
        ]
        guard let url = components?.url else {
            finishFetch(key: key, token: nil, expiresIn: 7200)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Don't let a single hung gettoken block every pending caller for that
        // corpid|corpsecret indefinitely.
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            var token: String?
            var expiresIn = 7200

            if error == nil, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Only a present, non-zero errcode means failure. WeChat always
                // returns a numeric errcode here, but a missing or NSNull value
                // must not discard a valid access_token.
                let errcode = (json["errcode"] as? NSNumber)?.intValue ?? 0
                if errcode == 0, let accessToken = json["access_token"] as? String {
                    token = accessToken
                }
                if let value = (json["expires_in"] as? NSNumber)?.intValue {
                    expiresIn = value
                } else if let value = (json["expires_in"] as? String), let parsed = Int(value) {
                    expiresIn = parsed
                }
            }
            finishFetch(key: key, token: token, expiresIn: expiresIn)
        }.resume()
    }

    /// Caches the token and releases every waiter in one critical section.
    ///
    /// Doing this atomically prevents a concurrent refresh from observing the
    /// new token while the old fetch is still registered, which could otherwise
    /// let it invalidate the fresh token and then be handed the same token it
    /// wanted to replace.
    private static func finishFetch(key: String, token: String?, expiresIn: Int) {
        lock.lock()
        if let token, !token.isEmpty {
            cache[key] = Entry(
                token: token,
                expiresAt: Date(timeIntervalSinceNow: cacheLifetime(for: expiresIn)),
                expiresIn: expiresIn
            )
        }
        let waiters = pending[key] ?? []
        pending.removeValue(forKey: key)
        lock.unlock()

        let result = (token?.isEmpty == false) ? token : nil
        for waiter in waiters { waiter(result) }
    }

    /// The token's cache lifetime, a minute short of what WeChat reported.
    ///
    /// A server value of 60 seconds or less is used as-is rather than being
    /// extended to the two-hour default: only a *missing* `expires_in` falls
    /// back to the default.
    private static func cacheLifetime(for expiresIn: Int) -> TimeInterval {
        if expiresIn > 60 { return TimeInterval(expiresIn - 60) }
        if expiresIn > 0 { return TimeInterval(expiresIn) }
        return 7200 - 60
    }
}
