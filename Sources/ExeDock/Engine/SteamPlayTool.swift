import Foundation

/// Playdock's own Steam compatibility tool: the documented `compatibilitytools.d` layout plus a
/// runner that starts the Windows exe with Playdock's Wine.
enum SteamPlayTool {
    static let toolID = "playdock"
    static let displayName = "Playdock Wine"

    static func compatibilitytoolVDF() -> String {
        """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "\(toolID)"
            {
              "install_path" "."
              "display_name" "\(displayName)"
              "from_oslist" "windows"
              "to_oslist" "macos"
            }
          }
        }

        """
    }

    static func toolmanifestVDF() -> String {
        """
        "manifest"
        {
          "version" "2"
          "commandline" "/run %verb%"
        }

        """
    }

    static func runScript() -> String {
        """
        #!/bin/sh
        # Playdock Steam Play. Steam calls: run waitforexitandrun <windows-exe> [args]
        set -e
        ENV_FILE="${PLAYDOCK_STEAMPLAY_ENV:-$HOME/Library/Application Support/ExeDock/SteamPlay/env.sh}"
        if [ -f "$ENV_FILE" ]; then
          . "$ENV_FILE"
        fi
        if [ "$1" = "run" ] || [ "$1" = "waitforexitandrun" ] || [ "$1" = "waitforexit" ]; then
          shift
        fi
        if [ "$1" = "waitforexitandrun" ]; then
          shift
        fi
        EXE="$1"
        if [ -z "$EXE" ]; then
          echo "Playdock Steam Play: no executable" >&2
          exit 1
        fi
        shift || true
        if [ -z "$WINELOADER" ] || [ ! -x "$WINELOADER" ]; then
          echo "Playdock Steam Play: Wine is not configured. Open Playdock and tap Set up Steam Play." >&2
          exit 1
        fi
        exec "$WINELOADER" start /unix "$EXE" "$@"

        """
    }

    static func envScript(wineLoader: String, prefixPath: String, libraryPath: String, extra: [String: String]) -> String {
        var lines = [
            "export WINELOADER=\(shQuote(wineLoader))",
            "export WINEPREFIX=\(shQuote(prefixPath))",
        ]
        if !libraryPath.isEmpty {
            lines.append("export DYLD_FALLBACK_LIBRARY_PATH=\(shQuote(libraryPath))")
        }
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(shQuote(value))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func install(into toolRoot: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: toolRoot, withIntermediateDirectories: true)
        try compatibilitytoolVDF().write(toFile: (toolRoot as NSString).appendingPathComponent("compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try toolmanifestVDF().write(toFile: (toolRoot as NSString).appendingPathComponent("toolmanifest.vdf"), atomically: true, encoding: .utf8)
        let runPath = (toolRoot as NSString).appendingPathComponent("run")
        try runScript().write(toFile: runPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runPath)
    }

    static func writeEnvironment(to supportDir: String, wineLoader: String, prefixPath: String, libraryPath: String, extra: [String: String]) throws {
        try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let text = envScript(wineLoader: wineLoader, prefixPath: prefixPath, libraryPath: libraryPath, extra: extra)
        try text.write(toFile: (supportDir as NSString).appendingPathComponent("env.sh"), atomically: true, encoding: .utf8)
    }

    static func isInstalled(in toolRoot: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: (toolRoot as NSString).appendingPathComponent("run"))
    }

    private static func shQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
