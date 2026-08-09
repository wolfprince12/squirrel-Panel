//
//  GitHubMirrorFetch.swift
//  Squirrel Panel
//
//  GitHub 网络请求镜像 fallback。中国大陆用户直连 GitHub 常被 403/超时/SSL 错误拦截，
//  本工具先尝试直连，失败后再逐个尝试公共镜像，任一成功即返回。
//
//  策略：
//    1. 普通 GET / 下载：原始 URL → 镜像 URL
//    2. Release 最新版本：API 直连 → 镜像 API → 镜像 release 页面（从 final URL 解析 tag）
//    3. Commit 最新 SHA：API 直连 → 镜像 API
//

import Foundation

enum GitHubMirrorFetch {
  /// 内置的 GitHub 镜像前缀列表（按优先级）。把原始 URL 直接拼到前缀后即可访问。
  static let mirrorPrefixes: [String] = [
    "https://ghproxy.com/",
    "https://mirror.ghproxy.com/",
    "https://github.moeyy.xyz/",
    "https://ghp.ci/",
    "https://gh.api.99988866.xyz/"
  ]

  /// 判断某个 URL 是否指向 GitHub 域名（含 api.github.com / github.com / raw.githubusercontent.com）
  static func isGitHubURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return false }
    return host.hasSuffix("github.com") || host.hasSuffix("githubusercontent.com")
  }

  /// 把原始 GitHub URL 用指定镜像前缀包裹，生成镜像 URL 字符串
  static func mirroredURL(_ original: String, prefix: String) -> String {
    let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
    if prefix.hasSuffix("/") {
      return prefix + trimmed
    }
    return prefix + "/" + trimmed
  }

  /// 生成候选 URL 列表：原始 URL + 各个镜像 URL
  static func candidateURLs(for original: String) -> [String] {
    guard isGitHubURL(original) else { return [original] }
    var result = [original]
    for prefix in mirrorPrefixes {
      result.append(mirroredURL(original, prefix: prefix))
    }
    return result
  }

  /// 使用 GET 请求获取数据，自动按候选 URL fallback。
  /// - Returns: (原始数据, 最终响应, 实际使用的 URL)
  /// - Throws: 所有候选 URL 都失败时，抛出最后一个错误；没有任何候选时抛出 invalidURL。
  static func fetch(
    from originalURL: String,
    headers: [String: String] = [:],
    timeout: TimeInterval = 20
  ) async throws -> (Data, HTTPURLResponse, String) {
    let candidates = candidateURLs(for: originalURL)
    guard !candidates.isEmpty else {
      throw URLError(.badURL)
    }

    var lastError: Error?
    for urlString in candidates {
      guard let url = URL(string: urlString) else {
        lastError = URLError(.badURL)
        continue
      }
      var req = URLRequest(url: url, timeoutInterval: timeout)
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      for (key, value) in headers {
        req.setValue(value, forHTTPHeaderField: key)
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
          lastError = URLError(.badServerResponse)
          continue
        }
        guard (200...299).contains(http.statusCode) else {
          // 403/401 等通常意味着该镜像也被限流或不可用，继续下一个候选
          lastError = GitHubMirrorFetchError.httpStatus(http.statusCode, urlString)
          continue
        }
        return (data, http, urlString)
      } catch {
        lastError = error
        continue
      }
    }

    throw lastError ?? URLError(.cannotConnectToHost)
  }

  /// 用 HEAD 请求获取远程文件大小（Content-Length），自动按候选 URL fallback。
  /// 用于语法模型（固定 LTS tag）的「有更新」判定：比对远程 .gram 大小与本地记录。
  /// - Returns: 第一个成功响应的 Content-Length（字节）；全部失败返回 nil。
  static func contentLength(forURLs urls: [String], timeout: TimeInterval = 20) async -> Int? {
    for urlString in urls {
      guard let url = URL(string: urlString) else { continue }
      var req = URLRequest(url: url, timeoutInterval: timeout)
      req.httpMethod = "HEAD"
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      do {
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else { continue }
        if let lenStr = http.allHeaderFields["Content-Length"] as? String,
           let len = Int(lenStr), len > 0 {
          return len
        }
      } catch {
        continue
      }
    }
    return nil
  }

  /// 专门获取 GitHub Release 最新版本信息。
  /// 先尝试 GitHub Release API（直连+镜像），再尝试镜像 release 页面并从 final URL 解析 tag。
  /// - Returns: (tag_name, html_url, 实际请求的 URL)
  static func fetchLatestRelease(repo: String) async throws -> (tag: String, htmlURL: String?, usedURL: String) {
    let apiURL = "https://api.github.com/repos/\(repo)/releases/latest"

    // 1) 尝试 API（直连 + 镜像）
    let apiCandidates = candidateURLs(for: apiURL)
    var lastError: Error?
    for urlString in apiCandidates {
      guard let url = URL(string: urlString) else { continue }
      var req = URLRequest(url: url, timeoutInterval: 20)
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          lastError = GitHubMirrorFetchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, urlString)
          continue
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tagName = obj["tag_name"] as? String {
          let htmlURL = obj["html_url"] as? String
          return (tagName, htmlURL, urlString)
        }
      } catch {
        lastError = error
        continue
      }
    }

    // 2) API 全部失败时，尝试 release 页面（仅镜像，因为直连失败才来这）
    let releasePage = "https://github.com/\(repo)/releases/latest"
    let pageCandidates = candidateURLs(for: releasePage)
    for urlString in pageCandidates {
      guard let url = URL(string: urlString) else { continue }
      var req = URLRequest(url: url, timeoutInterval: 20)
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      // 允许跟随重定向
      do {
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url?.absoluteString else {
          continue
        }
        // GitHub release latest 会 302 到 /releases/tag/<tag>；镜像通常保留这个结构
        if let tag = parseTagFromReleaseURL(finalURL) {
          return (tag, finalURL, urlString)
        }
      } catch {
        continue
      }
    }

    throw lastError ?? GitHubMirrorFetchError.unexpectedResponse
  }

  /// 从 release 页面 final URL 中解析 tag，例如：
  /// https://github.com/rime/squirrel/releases/tag/1.0.2  -> 1.0.2
  /// https://ghproxy.com/https://github.com/rime/squirrel/releases/tag/1.0.2  -> 1.0.2
  static func parseTagFromReleaseURL(_ urlString: String) -> String? {
    // 统一用正则匹配 github.com/{owner}/{repo}/releases/tag/{tag}
    let pattern = #"github\.com/[^/]+/[^/]+/releases/tag/([^/?#]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    guard let match = regex.firstMatch(
      in: urlString, options: [],
      range: NSRange(location: 0, length: urlString.utf16.count)) else { return nil }
    let range = match.range(at: 1)
    guard let swiftRange = Range(range, in: urlString) else { return nil }
    let tag = String(urlString[swiftRange])
    return tag.isEmpty ? nil : tag
  }

  /// 专门获取 GitHub 仓库某分支的最新 commit。
  /// 先尝试 API（直连+镜像），失败后再尝试 `/commit/{branch}` 页面重定向解析 SHA。
  /// - Returns: (sha, commit date, 实际请求的 URL)
  static func fetchLatestCommit(owner: String, repo: String, branch: String) async throws -> (sha: String, date: Date?, usedURL: String) {
    let apiURL = "https://api.github.com/repos/\(owner)/\(repo)/commits?sha=\(branch)&per_page=1"

    // 1) 尝试 API（直连 + 镜像）
    var apiLastError: Error?
    let apiCandidates = candidateURLs(for: apiURL)
    for urlString in apiCandidates {
      guard let url = URL(string: urlString) else { continue }
      var req = URLRequest(url: url, timeoutInterval: 20)
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          apiLastError = GitHubMirrorFetchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, urlString)
          continue
        }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let sha = first["sha"] as? String {
          var date: Date? = nil
          if let commit = first["commit"] as? [String: Any],
             let author = commit["author"] as? [String: Any],
             let dateStr = author["date"] as? String {
            date = ISO8601DateFormatter().date(from: dateStr)
          }
          return (sha, date, urlString)
        }
      } catch {
        apiLastError = error
        continue
      }
    }

    // 2) API 全部失败时，尝试 commits 页面 HTML：最新 commit SHA 会出现在页面链接中。
    // 注意：/commit/{branch} 会被 CDN 缓存并返回旧提交，/commits/{branch} 才是分支提交列表。
    let commitPage = "https://github.com/\(owner)/\(repo)/commits/\(branch)"
    let pageCandidates = candidateURLs(for: commitPage)
    for urlString in pageCandidates {
      guard let url = URL(string: urlString) else { continue }
      var req = URLRequest(url: url, timeoutInterval: 20)
      req.setValue("SquirrelPanel/1.0.0", forHTTPHeaderField: "User-Agent")
      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
          continue
        }
        if let sha = parseSHAFromCommitPage(html, owner: owner, repo: repo) {
          return (sha, nil, urlString)
        }
      } catch {
        continue
      }
    }

    throw apiLastError ?? GitHubMirrorFetchError.unexpectedResponse
  }

  /// 从 GitHub commit 页面 HTML 中解析最新 commit SHA。
  /// 匹配形如 href="/{owner}/{repo}/commit/abcdef123456..." 的链接。
  static func parseSHAFromCommitPage(_ html: String, owner: String, repo: String) -> String? {
    let pattern = #"href=\"/?\#(NSRegularExpression.escapedPattern(for: owner))/\#(NSRegularExpression.escapedPattern(for: repo))/commit/([a-fA-F0-9]{7,40})\""#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let nsrange = NSRange(html.startIndex..., in: html)
    // 正则只有 1 个捕获组（SHA），索引为 1。
    // 前置检查 numberOfRanges，避免 range(at:) 索引越界抛 ObjC 异常导致进程崩溃。
    guard let match = regex.firstMatch(in: html, options: [], range: nsrange),
          match.numberOfRanges > 1 else { return nil }
    let shaRange = match.range(at: 1)
    guard shaRange.location != NSNotFound,
          let swiftRange = Range(shaRange, in: html) else { return nil }
    let sha = String(html[swiftRange])
    return sha.count == 40 ? sha : nil
  }

  /// 下载文件（zip 等），自动 fallback 镜像。
  /// 对 .zip 文件额外校验文件签名（PK\x03\x04），避免 mirror 返回 HTML 错误页或截断数据。
  static func download(from originalURL: String, to destination: URL, timeout: TimeInterval = 60) async throws {
    let (data, _, _) = try await fetch(from: originalURL, timeout: timeout)
    guard !data.isEmpty else {
      throw GitHubMirrorFetchError.emptyResponse
    }
    if originalURL.lowercased().hasSuffix(".zip") {
      let zipSignature = Data([0x50, 0x4B, 0x03, 0x04])
      guard data.count >= zipSignature.count,
            data.prefix(zipSignature.count) == zipSignature else {
        throw GitHubMirrorFetchError.unexpectedResponse
      }
    }
    try data.write(to: destination, options: .atomic)
  }
}

enum GitHubMirrorFetchError: LocalizedError {
  case httpStatus(Int, String)
  case unexpectedResponse
  case emptyResponse

  var errorDescription: String? {
    switch self {
    case .httpStatus(let code, let url):
      return "HTTP \(code): \(url)"
    case .unexpectedResponse:
      return String(localized: "mirror.error.unexpected")
    case .emptyResponse:
      return String(localized: "mirror.error.empty")
    }
  }
}
