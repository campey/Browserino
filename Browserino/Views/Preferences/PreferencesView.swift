//
//  PreferencesView.swift
//  Browserino
//
//  Created by Aleksandr Strizhnev on 06.06.2024.
//

import AppKit
import SwiftUI

extension NSTableView {
    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        backgroundColor = NSColor.clear
        enclosingScrollView?.drawsBackground = false
    }
}

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(0)
            
            BrowsersTab()
                .tabItem {
                    Label("Browsers", systemImage: "gear")
                }
                .tag(1)

            ProfilesTab()
                .tabItem {
                    Label("Profiles", systemImage: "gear")
                }
                .tag(2)

            AppsTab()
                .tabItem {
                    Label("Apps", systemImage: "gear")
                }
                .tag(3)

            RulesTab()
                .tabItem {
                    Label("Rules", systemImage: "gear")
                }
                .tag(4)

            BrowserSearchLocationsTab()
                .tabItem {
                    Label("Locations", systemImage: "gear")
                }
                .tag(5)

            PhishingTab()
                .tabItem {
                    Label("Phishing", systemImage: "exclamationmark.shield")
                }
                .tag(6)

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "gear")
                }
                .tag(7)
        }
        .frame(minWidth: 780, minHeight: 500)
    }
}

struct PhishingTab: View {
    @AppStorage("phishingDetectionEnabled") private var phishingDetectionEnabled: Bool = false
    @AppStorage("phishingBlocklist") private var phishingBlocklist: [String] = []
    @AppStorage("showUrlPreview") private var showUrlPreview: Bool = false
    @AppStorage("resolveRedirects") private var resolveRedirects: Bool = false

    @State private var newDomain: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 32) {
                    Text("Detection")
                        .font(.headline)
                        .frame(width: 200, alignment: .trailing)

                    VStack(alignment: .leading) {
                        Toggle(isOn: $phishingDetectionEnabled) {
                            Text("Block known phishing & simulation hosts")
                                .font(.callout)
                                .opacity(0.5)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 32) {
                    Text("URL preview")
                        .font(.headline)
                        .frame(width: 200, alignment: .trailing)

                    VStack(alignment: .leading) {
                        Toggle(isOn: $showUrlPreview) {
                            Text("Show URL path and query in prompt (anti-phishing)")
                                .font(.callout)
                                .opacity(0.5)
                        }

                        Toggle(isOn: $resolveRedirects) {
                            Text("Show redirect peek button (resolves wrapped links)")
                                .font(.callout)
                                .opacity(0.5)
                        }
                        .disabled(!showUrlPreview)
                    }
                }

                HStack(alignment: .top, spacing: 32) {
                    Text("Blocklist")
                        .font(.headline)
                        .frame(width: 200, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 8) {
                        List {
                            ForEach(phishingBlocklist.indices, id: \.self) { i in
                                HStack {
                                    Text(phishingBlocklist[i])
                                        .font(.system(size: 13).monospaced())
                                    Spacer()
                                    Button(action: { phishingBlocklist.remove(at: i) }) {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(max(phishingBlocklist.count, 2)) * 36, 220))

                        HStack {
                            TextField("Domain (e.g. badsite.com)", text: $newDomain)
                                .frame(width: 220)
                                .onSubmit { addDomain() }

                            Button("Add") { addDomain() }
                        }

                        Text("Suffix match — example.com blocks example.com and foo.example.com")
                            .font(.caption)
                            .opacity(0.4)
                    }
                }
            }
            .padding(20)
        }
    }

    private func addDomain() {
        var d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        if d.hasPrefix("*.") { d = String(d.dropFirst(2)) }
        guard !d.isEmpty,
              !d.contains("/"),
              !d.contains(" "),
              !phishingBlocklist.contains(d) else { return }
        phishingBlocklist.append(d)
        newDomain = ""
    }
}

#Preview {
    PreferencesView()
}
