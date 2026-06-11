//
//  PromptView.swift
//  Browserino
//
//  Created by Aleksandr Strizhnev on 06.06.2024.
//

import AppKit
import SwiftUI

struct ResolvedHop: Identifiable {
    let id = UUID()
    let url: URL
    let statusCode: Int
}

private final class RedirectTracker: NSObject, URLSessionTaskDelegate {
    private(set) var hops: [ResolvedHop] = []
    private let maxHops: Int

    init(maxHops: Int = 10) { self.maxHops = maxHops }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        hops.append(ResolvedHop(url: response.url ?? request.url!, statusCode: response.statusCode))
        completionHandler(hops.count < maxHops ? request : nil)
    }
}

actor URLResolver {
    static let shared = URLResolver()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    func resolve(_ url: URL) async throws -> [ResolvedHop] {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let tracker = RedirectTracker()
        let (_, resp) = try await session.data(for: req, delegate: tracker)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        var hops = tracker.hops
        hops.append(ResolvedHop(url: http.url ?? url, statusCode: http.statusCode))

        if http.statusCode >= 400 && tracker.hops.isEmpty {
            var getReq = URLRequest(url: url)
            getReq.httpMethod = "GET"
            getReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            getReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let retryTracker = RedirectTracker()
            let (_, retryResp) = try await session.data(for: getReq, delegate: retryTracker)
            if let retryHttp = retryResp as? HTTPURLResponse {
                var retryHops = retryTracker.hops
                retryHops.append(ResolvedHop(url: retryHttp.url ?? url, statusCode: retryHttp.statusCode))
                return retryHops
            }
        }

        return hops
    }
}

struct PhishingMatch {
    let domain: String
    let reason: String
    let builtIn: Bool
}

enum PhishingDetector {
    static let builtInPatterns: [(domain: String, reason: String)] = [
        ("kb4.io",             "Phishing simulation (KnowBe4)"),
        ("malwarebouncer.com", "Phishing simulation (KnowBe4)"),
    ]

    static func match(host: String, userBlocklist: [String]) -> PhishingMatch? {
        let normalized = host.lowercased()
        for raw in userBlocklist {
            let d = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !d.isEmpty, matches(host: normalized, domain: d) {
                return PhishingMatch(domain: d, reason: "Matched blocklist entry", builtIn: false)
            }
        }
        return nil
    }

    private static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

struct PickerBrowserItem: Identifiable {
    let id: String
    let appURL: URL
    let displayName: String?
    let profileDirectory: String?
    let shortcutKey: String?
}

struct PromptView: View {
    @AppStorage("browsers") private var browsers: [URL] = []
    @AppStorage("hiddenBrowsers") private var hiddenBrowsers: [URL] = []
    @AppStorage("apps") private var apps: [App] = []
    @AppStorage("shortcuts") private var shortcuts: [String: String] = [:]
    @AppStorage("chromeProfiles") private var chromeProfiles: [ChromeProfile] = []
    @AppStorage("chromeProfilesEnabled") private var chromeProfilesEnabled: Bool = true

    @AppStorage("copy_closeAfterCopy") private var closeAfterCopy: Bool = false
    @AppStorage("copy_alternativeShortcut") private var alternativeShortcut: Bool = false
    @AppStorage("apps_atTop") private var appsAtTop: Bool = true
    @AppStorage("showUrlPreview") private var showUrlPreview: Bool = false
    @AppStorage("url_atTop") private var urlAtTop: Bool = false
    @AppStorage("twoColumnBrowsers") private var twoColumnBrowsers: Bool = false
    @AppStorage("resolveRedirects") private var resolveRedirects: Bool = false
    @AppStorage("phishingDetectionEnabled") private var phishingDetectionEnabled: Bool = false
    @AppStorage("phishingBlocklist") private var phishingBlocklist: [String] = []

    let urls: [URL]

    @State private var opacityAnimation = 0.0
    @State private var selected = 0
    @State private var pathExpanded = false
    @State private var queryExpanded = false
    @State private var resolvedURL: URL? = nil
    @State private var resolveError: String? = nil
    @State private var resolving = false
    @State private var peekActive = false
    @State private var phishingOverridden = false
    @FocusState private var focused: Bool

    @MainActor
    private func peekRedirects() async {
        guard let url = urls.first else { return }
        resolving = true
        resolveError = nil
        do {
            let hops = try await URLResolver.shared.resolve(url)
            resolvedURL = hops.last?.url
            peekActive = true
        } catch {
            resolveError = error.localizedDescription
        }
        resolving = false
    }

    var appsForUrls: [App] {
        urls.flatMap { url in
            return apps.filter { app in
                url.matchesHost(app.host)
            }
        }
        .filter {
            !browsers.contains($0.app)
        }
    }

    var visibleBrowsers: [URL] {
        browsers.filter { !hiddenBrowsers.contains($0) }
    }

    var pickerBrowserItems: [PickerBrowserItem] {
        var items: [PickerBrowserItem] = []

        for browser in visibleBrowsers {
            guard let bundle = Bundle(url: browser) else { continue }
            let bundleID = bundle.bundleIdentifier ?? ""

            if chromeProfilesEnabled && bundleID == ChromeProfileUtil.chromeBundleID {
                let visibleProfiles = chromeProfiles.filter { !$0.isHidden }
                if !visibleProfiles.isEmpty {
                    for profile in visibleProfiles {
                        let profileID = "\(bundleID)::\(profile.directoryName)"
                        let chromeName = bundle.infoDictionary?["CFBundleName"] as? String ?? "Google Chrome"
                        items.append(PickerBrowserItem(
                            id: profileID,
                            appURL: browser,
                            displayName: "\(chromeName) - \(profile.displayName)",
                            profileDirectory: profile.directoryName,
                            shortcutKey: shortcuts[profileID]
                        ))
                    }
                    continue
                }
            }

            items.append(PickerBrowserItem(
                id: bundleID,
                appURL: browser,
                displayName: nil,
                profileDirectory: nil,
                shortcutKey: shortcuts[bundleID]
            ))
        }

        return items
    }

    var totalItemCount: Int {
        pickerBrowserItems.count + appsForUrls.count
    }

    func openUrlsInApp(app: App) {
        let urls =
            if app.schemeOverride.isEmpty {
                urls
            } else {
                urls.map {
                    let url = NSURLComponents.init(
                        url: $0,
                        resolvingAgainstBaseURL: true
                    )
                    url!.scheme = app.schemeOverride

                    return url!.url!
                }
            }

        BrowserUtil.openURL(
            urls,
            app: app.app,
            isIncognito: false
        )
    }

    func openBrowserItem(_ item: PickerBrowserItem, isIncognito: Bool) {
        BrowserUtil.openURL(
            urls,
            app: item.appURL,
            isIncognito: isIncognito,
            profileDirectory: item.profileDirectory
        )
    }

    func handleEnter(isIncognito: Bool) {
        let browserItems = pickerBrowserItems
        if appsAtTop {
            if selected < appsForUrls.count {
                openUrlsInApp(app: appsForUrls[selected])
            } else {
                let idx = selected - appsForUrls.count
                if idx < browserItems.count {
                    openBrowserItem(browserItems[idx], isIncognito: isIncognito)
                }
            }
        } else {
            if selected < browserItems.count {
                openBrowserItem(browserItems[selected], isIncognito: isIncognito)
            } else {
                let idx = selected - browserItems.count
                if idx < appsForUrls.count {
                    openUrlsInApp(app: appsForUrls[idx])
                }
            }
        }
    }

    private var effectiveURL: URL? {
        (peekActive ? resolvedURL : nil) ?? urls.first
    }

    private var phishingMatch: PhishingMatch? {
        guard phishingDetectionEnabled,
              let host = urls.first?.host()?.lowercased() else { return nil }
        return PhishingDetector.match(host: host, userBlocklist: phishingBlocklist)
    }

    private var gridColumns: [GridItem] {
        twoColumnBrowsers
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible())]
    }

    @ViewBuilder
    private var urlDisplayContent: some View {
        if let displayURL = effectiveURL, let host = displayURL.host() {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(action: {
                        guard let url = effectiveURL else { return }
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(url.absoluteString, forType: .string)
                        if closeAfterCopy {
                            NSApplication.shared.keyWindow?.close()
                        }
                    }) {
                        Text(host)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(
                        KeyEquivalent("c"),
                        modifiers: alternativeShortcut ? [.command] : [.command, .option]
                    )
                    .toolTip(displayURL.absoluteString)

                    Spacer()

                    Button(action: {
                        guard let url = effectiveURL else { return }
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(url.absoluteString, forType: .string)
                        if closeAfterCopy {
                            NSApplication.shared.keyWindow?.close()
                        }
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.4)
                    .help("Copy URL (\(alternativeShortcut ? "⌘C" : "⌘⌥C"))")

                    if resolveRedirects {
                        if resolving {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button(action: {
                                if peekActive {
                                    peekActive = false
                                } else if resolvedURL != nil {
                                    peekActive = true
                                } else {
                                    Task { await peekRedirects() }
                                }
                            }) {
                                Image(systemName: peekActive ? "magnifyingglass.circle.fill" : "magnifyingglass")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .opacity(0.5)
                            .help(peekActive ? "Show original URL" : "Peek resolved destination")
                        }
                    }
                }

                if showUrlPreview {
                    let path = displayURL.path()
                    let query = displayURL.query()

                    if !path.isEmpty && path != "/" {
                        Button(action: { pathExpanded.toggle() }) {
                            Text(path)
                                .font(.caption)
                                .monospaced()
                                .lineLimit(pathExpanded ? nil : 1)
                                .truncationMode(.middle)
                                .opacity(0.6)
                        }
                        .buttonStyle(.plain)
                        .help(pathExpanded ? "Click to collapse" : "Click to expand")
                    }

                    if let q = query {
                        Button(action: { queryExpanded.toggle() }) {
                            Text("?\(q)")
                                .font(.caption)
                                .monospaced()
                                .lineLimit(queryExpanded ? nil : 1)
                                .truncationMode(.tail)
                                .opacity(0.6)
                        }
                        .buttonStyle(.plain)
                        .help(queryExpanded ? "Click to collapse" : "Click to expand")
                    }
                }

                if let error = resolveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .opacity(0.8)
                        .lineLimit(2)
                }
            }
        }
    }

    var body: some View {
        VStack {
            if urlAtTop {
                urlDisplayContent
                Divider()
            }

            if let match = phishingMatch, !phishingOverridden {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)

                    Text("Suspicious URL")
                        .font(.headline)

                    Text("Matched: \(match.domain)")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)

                    Text("May be a phishing test or malicious link. Verify before opening.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    HStack(spacing: 12) {
                        Button("Close") {
                            NSApplication.shared.keyWindow?.close()
                        }
                        .keyboardShortcut(.defaultAction)

                        Button("Open anyway") {
                            phishingOverridden = true
                        }
                        .tint(.red)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        opacityAnimation = 1
                    }
                }
            } else {
            ScrollViewReader { scrollViewProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if !appsForUrls.isEmpty && appsAtTop {
                            LazyVGrid(columns: gridColumns, spacing: 2) {
                                ForEach(Array(appsForUrls.enumerated()), id: \.offset) { index, app in
                                    if let bundle = Bundle(url: app.app) {
                                        PromptItem(
                                            browser: app.app,
                                            urls: urls,
                                            bundle: bundle,
                                            shortcut: shortcuts[bundle.bundleIdentifier!]
                                        ) {
                                            openUrlsInApp(app: app)
                                        }
                                        .id(index)
                                        .buttonStyle(
                                            SelectButtonStyle(
                                                selected: selected == index
                                            )
                                        )
                                    }
                                }
                            }

                            Divider()
                        }

                        LazyVGrid(columns: gridColumns, spacing: 2) {
                            ForEach(Array(pickerBrowserItems.enumerated()), id: \.element.id) {
                                index, item in
                                if let bundle = Bundle(url: item.appURL) {
                                    PromptItem(
                                        browser: item.appURL,
                                        urls: urls,
                                        bundle: bundle,
                                        shortcut: item.shortcutKey,
                                        displayName: item.displayName
                                    ) {
                                        openBrowserItem(item, isIncognito: NSEvent.modifierFlags.contains(.shift))
                                    }
                                    .id(index + (appsAtTop ? appsForUrls.count : 0))
                                    .buttonStyle(
                                        SelectButtonStyle(
                                            selected: selected == index + (appsAtTop ? appsForUrls.count : 0)
                                        )
                                    )
                                }
                            }
                        }

                        if !appsForUrls.isEmpty && !appsAtTop {
                            Divider()

                            LazyVGrid(columns: gridColumns, spacing: 2) {
                                ForEach(Array(appsForUrls.enumerated()), id: \.offset) { index, app in
                                    if let bundle = Bundle(url: app.app) {
                                        PromptItem(
                                            browser: app.app,
                                            urls: urls,
                                            bundle: bundle,
                                            shortcut: shortcuts[bundle.bundleIdentifier!]
                                        ) {
                                            openUrlsInApp(app: app)
                                        }
                                        .id(pickerBrowserItems.count + index)
                                        .buttonStyle(
                                            SelectButtonStyle(
                                                selected: selected == pickerBrowserItems.count + index
                                            )
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabledCompat()
                .focused($focused)
                .onMoveCommand { command in
                    if command == .up {
                        selected = max(0, selected - 1)
                        scrollViewProxy.scrollTo(selected, anchor: .center)
                    } else if command == .down {
                        selected = min(totalItemCount - 1, selected + 1)
                        scrollViewProxy.scrollTo(selected, anchor: .center)
                    }
                }
                .background {
                    Button(action: {
                        handleEnter(isIncognito: false)
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.defaultAction)

                    Button(action: {
                        handleEnter(isIncognito: true)
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.return, modifiers: [.shift])

                    Button(action: {
                        NSApplication.shared.keyWindow?.close()
                    }) {}
                    .opacity(0)
                    .keyboardShortcut(.cancelAction)
                }
                .onAppear {
                    focused.toggle()
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        opacityAnimation = 1
                    }
                }
                .scrollEdgeEffectDisabledCompat()
            }
            } // end phishing else

            if !urlAtTop {
                Divider()
                urlDisplayContent
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .background(BlurredView())
        .opacity(opacityAnimation)
        .edgesIgnoringSafeArea(.all)
    }
}

#Preview {
    PromptView(urls: [])
}
