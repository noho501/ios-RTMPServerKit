import UIKit
import Network
import RTMPServerKit

final class ViewController: UIViewController {
    // MARK: - Properties

    private let server = RTMPServer()
    private let previewView = RTMPPreviewView()

    private let urlLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.adjustsFontSizeToFitWidth = true
        return l
    }()

    private let streamKeyLabel: UILabel = {
        let l = UILabel()
        l.textColor = .systemYellow
        l.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        l.textAlignment = .center
        l.text = "Stream key: test"
        return l
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.textColor = .systemGreen
        l.font = .systemFont(ofSize: 13)
        l.textAlignment = .center
        l.text = "Waiting for stream…"
        return l
    }()

    private let statsLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.text = "In: 0 fps  Render: 0 fps  Drop: 0 fps\nBitrate: 0 kbps  Queue: 0  Delay: 0 ms  0x0"
        return l
    }()

    private let overlayView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        return v
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        startServer()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Full-screen preview
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Overlay at the bottom
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            overlayView.heightAnchor.constraint(equalToConstant: 145)
        ])

        let stack = UIStackView(arrangedSubviews: [urlLabel, streamKeyLabel, statusLabel, statsLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor)
        ])
    }

    // MARK: - Server

    private func startServer() {
        previewView.preferredPlayoutDelay = 0.8
        previewView.preferredMaxQueueDepth = 32
        previewView.onStats = { [weak self] stats in
            let text = String(
                format: "In: %.1f fps  Render: %.1f fps  Drop: %.1f fps\nBitrate: %.0f kbps  Queue: %d  Delay: %d ms  %dx%d",
                stats.incomingFPS,
                stats.renderedFPS,
                stats.droppedFPS,
                stats.bitrateKbps,
                stats.queueDepth,
                stats.playoutDelayMs,
                Int(stats.width),
                Int(stats.height)
            )
            self?.statsLabel.text = text
        }
        previewView.attach(server: server)

        server.onPublish = { [weak self] key in
            self?.previewView.resetStreamState()
            self?.statusLabel.text = "🔴 Publishing: \(key)"
        }
        server.onDisconnect = { [weak self] in
            self?.previewView.resetStreamState()
            self?.statusLabel.text = "Waiting for stream…"
        }

        do {
            try server.start(port: 1935)
            let ip = deviceIPAddress() ?? "?.?.?.?"
            urlLabel.text = "rtmp://\(ip)/live"
        } catch {
            statusLabel.text = "Failed to start: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func deviceIPAddress() -> String? {
        var wifiAddress: String?
        var otherAddress: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            guard let ifa_addr = current.pointee.ifa_addr else {
                ptr = current.pointee.ifa_next
                continue
            }
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback {
                let family = Int32(ifa_addr.pointee.sa_family)
                if family == AF_INET {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        ifa_addr,
                        socklen_t(ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    let interface = String(cString: current.pointee.ifa_name)
                    if interface == "en0" {
                        wifiAddress = ip
                    } else if otherAddress == nil {
                        otherAddress = ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return wifiAddress ?? otherAddress
    }
}
