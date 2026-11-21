import Foundation
import AppKit

/// Which local agent CLI an agent task runs on. All of them are the same compliant
/// pattern — spawn the user's own official binary under their own sign-in — so
/// the runner only differs in argv and JSONL dialect.
enum AgentEngine: String, CaseIterable {
    case codex
    case claude
    case grok
    case commandCode
    case pi

    var displayName: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        case .grok:   return "Grok"
        case .commandCode: return "Command Code"
        case .pi:     return "PI"
        }
    }

    /// Installed + signed in, per the engine's own service.
    var isAvailable: Bool {
        switch self {
        case .codex:  return CodexCLIService.isAvailable
        case .claude: return ClaudeCLIService.isAvailable
        case .grok:   return GrokCLIService.isAvailable
        case .commandCode: return CommandCodeCLIService.isAvailable
        case .pi:     return PiCLIService.isAvailable
        }
    }

    /// Whether this engine's availability answer is FINAL, rather than the
    /// placeholder "no" a probe still in flight reports. `isAvailable` has to
    /// answer instantly from `body`, so on a cold cache it says `false` for every
    /// engine whose binary hasn't resolved yet — Command Code's probe is a Node
    /// cold start, ~2s after launch.
    var isAvailabilityResolved: Bool {
        switch self {
        case .codex:  return CodexCLIService.isAvailabilityResolved
        case .claude: return ClaudeCLIService.isAvailabilityResolved
        case .grok:   return GrokCLIService.isAvailabilityResolved
        case .commandCode: return CommandCodeCLIService.isAvailabilityResolved
        case .pi:     return PiCLIService.isAvailabilityResolved
        }
    }

    /// Known dead — resolved, and the answer was no. The ONLY safe trigger for
    /// dropping a remembered engine and the model pick under it: `!isAvailable`
    /// alone is true during every launch's probe window, and acting on it there
    /// is how a relaunch used to silently reset the armed model to the first
    /// engine's default.
    var isKnownUnavailable: Bool { isAvailabilityResolved && !isAvailable }

    /// Image input is wired only for the CLIs that expose a real headless image
    /// transport: Codex uses `-i`, while Claude accepts vision blocks through
    /// stream-json. The other runners must leave an image paste to AppKit instead
    /// of showing an attachment they would silently drop.
    var supportsImageInput: Bool {
        self == .codex || self == .claude
    }

    /// The terminal command that picks this engine's session back up. Neither
    /// CLI is spawned with `--ephemeral` / `--no-session-persistence`, so a run
    /// Notch lost track of (quit, crash) is still resumable by hand — the
    /// interrupted run's Recent row hands the user the exact line.
    func resumeCommand(session: String) -> String {
        switch self {
        case .codex:  return "codex resume \(session)"
        case .claude: return "claude --resume \(session)"
        case .grok:   return "grok --resume \(session)"
        // A headless Command Code session is hidden from the interactive picker but
        // opens fine when its id is named outright.
        case .commandCode: return "cmd --resume \(session)"
        // pi looks a session up by id within the folder it ran in, so this line is
        // only exact when the user runs it from that folder — same as the others.
        case .pi:     return "pi --session \(session)"
        }
    }

    /// The engines the app offers — every case except the retired `.commandCode`
    /// (see `CommandCodeCLIService.isRetired`). The case stays so past agent rows
    /// still decode and draw their engine; it is simply never listed again.
    static let offered: [AgentEngine] = allCases.filter { $0 != .commandCode }

    /// The engines that can actually run right now — drives the entry button
    /// (any) and the armed line's engine chip (a toggle only when both).
    static var available: [AgentEngine] { offered.filter(\.isAvailable) }

    /// The engine to arm by default: the last one used, if it's still available,
    /// else whichever is. Persisted whenever the armed engine changes.
    private static let defaultsKey = "agentEngine"
    static var preferred: AgentEngine? {
        if let stored = storedPreference, stored.isAvailable { return stored }
        return available.first
    }
    /// The raw remembered choice, with NO availability probe — safe to read on
    /// the main thread at model init (`isAvailable` shells out on a cold cache).
    static var storedPreference: AgentEngine? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentEngine.init)
    }
    static func rememberPreference(_ engine: AgentEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: defaultsKey)
    }

    /// This engine's entries in the armed row's model menu — named models only,
    /// no "CLI default" rung (a bare "Default" says nothing about what you'd
    /// get). Codex's pinnable ids come from the account's own `model/list`
    /// (fetched and cached by `CodexCLIService` at launch) — never hardcoded,
    /// because Codex has no rolling aliases and a retired id 404s the whole run.
    /// Claude's are the CLI's documented rolling aliases (they always point at
    /// the current lineup), since the Claude CLI has no model-list command to
    /// query. Codex keeps ONE fallback entry when that list hasn't landed
    /// (`id == nil` → the CLI's own default): the menu is also the only way to
    /// arm an engine, so an available engine must never have an empty section.
    var modelChoices: [AgentModelChoice] {
        switch self {
        case .codex:
            let listed = CodexCLIService.listedModels.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
            return listed.isEmpty
                ? [AgentModelChoice(engine: self, id: nil, label: displayName)]
                : listed
        case .claude:
            // The rolling aliases stay the pickable ids (they're what `--model`
            // takes), but each label names the CONCRETE model the alias points
            // at today — "Claude Opus 4.8", probed from the CLI and cached by
            // `ClaudeCLIService` — because a bare family word names a shelf,
            // not a model. Falls back to the family word until a probe lands.
            let resolved = ClaudeCLIService.resolvedModels
            return [("fable", "Claude Fable"), ("opus", "Claude Opus"),
                    ("sonnet", "Claude Sonnet")].map { alias, fallback in
                AgentModelChoice(
                    engine: self, id: alias,
                    label: resolved[alias].map(ClaudeCLIService.displayName(forResolved:))
                        ?? fallback)
            }
        case .grok:
            // Grok's models come from the CLI's own cache (see `GrokCLIService`),
            // labelled with the cache's display names ("Grok 4.5" — the id's bare
            // version tail says nothing in the list). An empty cache → the one
            // flag-less default entry (an available engine must never have an
            // empty section, since the menu is the only way to arm it).
            let listed = GrokCLIService.listedModels
            if listed.isEmpty {
                return [AgentModelChoice(engine: self, id: nil, label: displayName)]
            }
            return listed.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
        case .commandCode:
            // Command Code's catalog is the widest of the four (an aggregator: ~50
            // models across a dozen labs), read from the CLI itself — see
            // `CommandCodeCLIService`. Same empty-cache fallback as Grok's: an
            // available engine must never have an empty section.
            let listed = CommandCodeCLIService.listedModels
            if listed.isEmpty {
                return [AgentModelChoice(engine: self, id: nil, label: displayName)]
            }
            return listed.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
        case .pi:
            // pi's catalog is the widest of the five, because it is not one account's
            // lineup but every provider the user has signed pi into — read from the
            // CLI itself (see `PiCLIService`). Same empty-catalog fallback as the
            // other two: an available engine must never have an empty section.
            let listed = PiCLIService.listedModels
            if listed.isEmpty {
                return [AgentModelChoice(engine: self, id: nil, label: displayName)]
            }
            return listed.map {
                AgentModelChoice(engine: self, id: $0.id, label: $0.displayName)
            }
        }
    }
}

/// One pickable model for an agent run. The armed row's model chip mixes
/// every available engine's entries into a single menu — choosing a model
/// chooses its engine with it. `id == nil` is the engine's own CLI-config
/// default (no model flag passed at all).
struct AgentModelChoice: Hashable {
    let engine: AgentEngine
    /// The value for the engine's model flag (`-m` / `--model`); nil = default.
    let id: String?
    /// The menu / chip title. A nil-id entry (Codex before its model list lands)
    /// carries the plain engine name.
    let label: String
}

/// Reasoning effort for an agent run — the armed row's third chip. `nil`
/// (no selection) leaves both CLIs on their own defaults. The full ladder both
/// CLIs speak today; which rungs the menu actually offers comes from
/// `AgentEngine.effortChoices(forModelID:)`, since they differ per engine
/// and (for Codex) per model.
enum AgentEffort: String, CaseIterable {
    case low, medium, high, xhigh, max, ultra
}

extension AgentEngine {
    /// The effort levels pickable for a run on this engine + model pick — see
    /// `AgentEffortCatalog` for where each engine's answer comes from and why a
    /// hardcoded ladder isn't one.
    func effortChoices(forModelID modelID: String?) -> [AgentEffort] {
        AgentEffortCatalog.choices(engine: self, modelID: modelID)
    }
}

/// Which `--effort` levels an engine+model actually accepts.
///
/// This used to be three hardcoded ladders, and the Command Code one was wrong in
/// a way that **killed runs**: the CLI doesn't ignore a level it doesn't take, it
/// refuses the whole task before doing any work —
/// `Unknown effort "low". Supported: high, max.` Measured against the installed
/// CLI (v1.26.0, 55 models), the old `[.low, .medium, .high]` guess was right for
/// 7 of them; 29 accept no effort flag at all, and the CLI's own default model
/// (`deepseek/deepseek-v4-flash`) takes only `high`/`max` — which is exactly the
/// combination a fresh install hit.
///
/// The sets aren't even a ladder, so "clamp to the nearest rung" is no fix either:
/// `qwen/qwen3.8-max` takes `xhigh` but not `high`, `zai-org/glm-5.3` skips
/// `medium`. The only correct answer is the real set, so it comes from three
/// layers, most authoritative first:
///
///  1. **The installed binary** (`CommandCodeCLIService.effortLevels`) — a 1.3s
///     probe that spends no tokens, cached against the CLI's fingerprint. Only
///     the build on this Mac can answer for the build on this Mac, and Command
///     Code updates itself in the background, so no table we ship or serve can
///     know which build a given user is on.
///  2. **The remote manifest** (`RemoteModelManifest.efforts`) — the maintained
///     table on the website, so a CLI release that moves a model's set is fixed
///     without shipping an app update. It can also be told to *outrank* the probe
///     per engine (`effortsOverride`), which is the lever for a probe that has
///     started misreading the binary — off by default, since a probe that simply
///     fails already falls through to here.
///  3. **The bundled table below** — the same measurement baked in, so a fresh
///     offline install is already right.
///
/// That order is the one this app already uses for models: the vendor's own live
/// catalog supersedes the manifest, which supersedes the bundled spec
/// (`RemoteModelManifest`). The probe is the live catalog of this seam.
///
/// A model no layer knows offers **no rungs at all** (Default only, no `--effort`
/// sent). That is deliberate: sending an unverified level risks the run, and the
/// upside is one menu entry. The probe fills the menu in a second or so.
enum AgentEffortCatalog {
    static func choices(engine: AgentEngine, modelID: String?) -> [AgentEffort] {
        switch engine {
        case .codex:
            // Codex publishes the answer itself — each model's own
            // `supportedReasoningEfforts` from the app-server's `model/list` — so
            // it needs no table. For the default pick (`modelID == nil`) that's
            // the account-default model's set.
            let models = CodexCLIService.listedModels
            let picked = modelID.flatMap { id in models.first { $0.id == id } }
                ?? models.first(where: \.isDefault) ?? models.first
            // Until that list lands, the lowest common denominator every Codex
            // model accepts — unchanged from before, and safe because Codex is one
            // vendor's own lineup rather than an aggregator's.
            guard let picked else { return [.low, .medium, .high] }
            return picked.efforts.compactMap(AgentEffort.init)
        case .commandCode:
            // The one aggregator, and the one that hard-errors: ask the binary,
            // and kick a probe when it hasn't been asked about this model yet.
            let id = modelID ?? CommandCodeCLIService.defaultModel
            // The remote kill switch, normally off — see
            // `RemoteModelManifest.effortsOverridesProbe` for why the probe leads
            // by default (it's the only layer that can't be wrong about which CLI
            // build the user is actually running).
            if RemoteModelManifest.effortsOverridesProbe(engine: engine.rawValue),
               let curated = manifest(engine: engine, model: id) {
                return curated
            }
            if let probed = CommandCodeCLIService.effortLevels(for: modelID) {
                return probed.compactMap(AgentEffort.init)
            }
            CommandCodeCLIService.probeEfforts(for: modelID)
            return manifest(engine: engine, model: id)
                ?? bundledCommandCode[id]
                ?? []
        case .pi:
            // The other aggregator, and the only one that answers this for free: its
            // catalog carries a `thinking` column per model, so whether a pick takes
            // a `--thinking` level is already known — no probe, no bundled table. The
            // levels themselves are pi's own documented ladder, minus `off`/`minimal`
            // (which are "don't think", not efforts). Still routed through the
            // manifest first, so a wrong rung stays a website edit.
            let id = modelID ?? PiCLIService.defaultModel
            if let curated = manifest(engine: engine, model: id) { return curated }
            guard PiCLIService.supportsThinking(modelID) else { return [] }
            return [.low, .medium, .high, .xhigh, .max]
        case .claude, .grok:
            // Single-vendor CLIs with a documented, stable ladder (claude's
            // `--effort`, grok's `--reasoning-effort`). Left as the documented set,
            // but routed through the manifest first so a wrong rung is a website
            // edit rather than a release.
            let id = modelID ?? ""
            return manifest(engine: engine, model: id)
                ?? [.low, .medium, .high, .xhigh, .max]
        }
    }

    /// The maintained table's answer for this engine+model, mapped into the cases
    /// this app knows. An entry that exists but is empty means "no effort flag" and
    /// is returned as such — only a *missing* entry falls through to the next layer.
    private static func manifest(engine: AgentEngine, model: String) -> [AgentEffort]? {
        guard let levels = RemoteModelManifest.efforts(engine: engine.rawValue, model: model)
        else { return nil }
        return levels.compactMap(AgentEffort.init)
    }

    /// Command Code's table as measured against CLI v1.26.0 — the offline seed for
    /// layers 2 and 3 above. Grouped by set rather than listed per model, because
    /// that is how it reads: a whole vendor's rows usually move together.
    ///
    /// Regenerate by probing the installed CLI, which costs no tokens and answers
    /// in ~1.3s per model:
    ///
    ///     cmd -p hi -m <id> --effort __probe__ --no-auto-update --skip-onboarding
    private static let bundledCommandCode: [String: [AgentEffort]] = {
        let groups: [([AgentEffort], [String])] = [
            ([.low, .medium, .high, .xhigh, .max], [
                "claude-sonnet-5", "claude-sonnet-4-6",
                "claude-fable-5", "claude-opus-5",
                "claude-opus-4-8", "claude-opus-4-7",
                "gpt-5.6-sol", "gpt-5.6-terra",
                "gpt-5.6-luna"]),
            ([.low, .medium, .high, .xhigh], [
                "gpt-5.5", "gpt-5.4",
                "gpt-5.3-codex", "xai/grok-4.6"]),
            ([.low, .medium, .high], [
                "gpt-5.4-mini", "google/gemini-3.7-flash",
                "google/gemini-3.6-flash", "google/gemini-3.5-flash",
                "google/gemini-3.5-flash-lite", "google/gemini-3.1-flash-lite",
                "xai/grok-4.5"]),
            ([.high, .max], [
                "deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash",
                "zai-org/glm-5.2"]),
            ([.low, .high, .max], ["zai-org/glm-5.3"]),
            ([.low, .medium, .xhigh], ["qwen/qwen3.8-max"]),
            ([.high, .xhigh], ["sakana/fugu-ultra"]),
            // No adjustable reasoning effort — over half the fleet. The CLI says so
            // in as many words ("<Model> has no adjustable reasoning effort.").
            ([], [
                "moonshotai/kimi-k3", "moonshotai/kimi-k2.7-code",
                "moonshotai/kimi-k2.7-code-highspeed", "moonshotai/kimi-k2.6",
                "moonshotai/kimi-k2.5", "zai-org/glm-5.2-fast",
                "zai-org/glm-5.1", "zai-org/glm-5",
                "minimaxai/minimax-m3", "minimaxai/minimax-m2.7",
                "minimaxai/minimax-m2.5", "xiaomi/mimo-v2.5-pro",
                "xiaomi/mimo-v2.5", "qwen/qwen3.7-max",
                "qwen/qwen3.7-plus", "qwen/qwen3.7-flash",
                "qwen/qwen3.6-max-preview", "qwen/qwen3.6-plus",
                "stepfun/step-3.7-flash", "stepfun/step-3.5-flash",
                "tencent/hy3-paid", "nvidia/nemotron-3-ultra-550b-a55b",
                "thinkingmachines/inkling", "thinkingmachines/inkling-small",
                "poolside/laguna-s-2.1-free", "claude-haiku-4-5",
                "meta/muse-spark-1.1", "meta/muse-spark-1.2",
                "meta/muse-spark-1.2-contributor"]),
        ]
        var out: [String: [AgentEffort]] = [:]
        for (levels, ids) in groups {
            for id in ids { out[id] = levels }
        }
        return out
    }()
}
