//
//  RadarTilePrefetcher.swift
//  YAWA
//
//  Created by Keith Sharman on 1/15/26.
//


import Foundation

enum RadarTilePrefetcher {
    static func prefetch(urls: [URL], maxConcurrent: Int = 8) async {
        guard !urls.isEmpty else { return }

        let sem = AsyncSemaphore(value: maxConcurrent)

        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    await sem.wait()
                    defer { Task { await sem.signal() } }

                    var req = URLRequest(url: url)
                    req.cachePolicy = .returnCacheDataElseLoad
                    req.timeoutInterval = 6
                    print("[NET] prefetchRadar current START \(Date())")
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
    }
}

actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.value = value }

    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func signal() async {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        } else {
            value += 1
        }
    }
}
