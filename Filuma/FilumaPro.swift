import Foundation
import Observation
import StoreKit
import SwiftData
import SwiftUI

enum FilumaProProduct {
    static let monthly = "com.christoforakis.Filuma.pro.monthly"
    static let annual = "com.christoforakis.Filuma.pro.annual"
    static let all = [monthly, annual]
}

@MainActor
@Observable
final class FilumaProStore {
    enum EntitlementState: Equatable {
        case checking
        case free
        case pro
    }

    private(set) var entitlementState: EntitlementState
    private(set) var lastIssue: String?
    private var updatesTask: Task<Void, Never>?
    private let isUITesting: Bool
    private let isForcedFreeUITest: Bool

    var isPro: Bool { entitlementState == .pro }
    var isChecking: Bool { entitlementState == .checking }

    init(arguments: [String] = CommandLine.arguments) {
        isUITesting = arguments.contains("-ui-testing")
        isForcedFreeUITest = arguments.contains("-ui-testing-free")

        if isUITesting {
            // Existing UI journeys retain the full pre-subscription surface.
            // Dedicated free-tier tests opt in explicitly.
            entitlementState = isForcedFreeUITest ? .free : .pro
            FilumaProAccess.setVerifiedEntitlement(!isForcedFreeUITest)
            return
        }

        entitlementState = FilumaProAccess.isPro ? .pro : .checking
        updatesTask = observeTransactionUpdates()
        Task { await refreshEntitlements() }
    }

    func refreshEntitlements() async {
        guard !isUITesting else { return }
        var hasProEntitlement = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  FilumaProProduct.all.contains(transaction.productID) else {
                continue
            }
            hasProEntitlement = true
        }

        entitlementState = hasProEntitlement ? .pro : .free
        lastIssue = nil
        FilumaProAccess.setVerifiedEntitlement(hasProEntitlement)
    }

    func restorePurchases() async {
        lastIssue = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro {
                lastIssue = "No active Filuma Pro subscription was found for this Apple Account."
            }
        } catch {
            lastIssue = "Filuma couldn't reach the App Store. Nothing changed—try restoring again."
        }
    }

    func clearIssue() {
        lastIssue = nil
    }

    func grantProForUITesting() {
        guard isUITesting, isForcedFreeUITest else { return }
        entitlementState = .pro
        FilumaProAccess.setVerifiedEntitlement(true)
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                }
                await self?.refreshEntitlements()
            }
        }
    }
}

enum ProFeature: String, Identifiable {
    case general
    case taskLimit
    case weave
    case integrations
    case repeatTasks
    case planning
    case widgets

    var id: String { rawValue }

    var eyebrow: String {
        switch self {
        case .taskLimit: "Your first three threads are free"
        case .weave: "Keep the whole story"
        case .integrations: "Plan around real life"
        case .repeatTasks: "Set the rhythm once"
        case .planning: "Shape the plan to fit you"
        case .widgets: "Keep the next step close"
        case .general: "Make more room at the hearth"
        }
    }

    var title: String {
        switch self {
        case .taskLimit: "Keep every active task moving"
        case .weave: "Unlock your full Weave"
        case .integrations: "Connect your calendars"
        case .repeatTasks: "Let weekly work return gently"
        case .planning: "Tune every planning boundary"
        case .widgets: "Bring Filuma to your Home Screen"
        case .general: "Unlock Filuma Pro"
        }
    }

    var message: String {
        switch self {
        case .taskLimit:
            "Filuma Free keeps three active tasks in motion. Pro makes the plan unlimited without hiding or deleting anything you already captured."
        case .weave:
            "See the last two weeks of starts, sessions, finished work, and rest days as one calm record of showing up."
        case .integrations:
            "Schedule around Apple and Google Calendar, keep blocked times, and mirror work blocks into the calendar you already use."
        case .repeatTasks:
            "Create weekly tasks once and let Filuma place each new occurrence around that week's actual availability."
        case .planning:
            "Adjust focus limits, block sizes, deadline buffers, and start buffers while Filuma rebuilds the plan honestly."
        case .widgets:
            "See what is next from the Home Screen and Lock Screen, with Live Activities while a session is running."
        case .general:
            "Unlimited active tasks, calendar integrations, widgets, weekly repeats, advanced planning controls, and your full Weave."
        }
    }
}

struct ProLockedFeatureView: View {
    let feature: ProFeature
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            HearthScreenBackground(
                topGlow: 0.22,
                bottomGlow: 0.3,
                embers: reduceMotion ? 0 : 12,
                emberIntensity: 0.7
            )

            VStack(spacing: 20) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.brand300)
                    .frame(width: 64, height: 64)
                    .background(Color.brand500.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(Color.brand300.opacity(0.18)))
                    .hearthGlow(.brand500, radius: 24, opacity: 0.42)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(feature.eyebrow)
                        .font(AppFont.caption(12))
                        .foregroundStyle(Color.brand300)
                    Text(feature.title)
                        .font(AppFont.title(28))
                        .foregroundStyle(Color.filumaText)
                        .multilineTextAlignment(.center)
                    Text(feature.message)
                        .font(AppFont.body(15))
                        .foregroundStyle(Color.filumaSubtle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                Button(action: action) {
                    Label("See Filuma Pro", systemImage: "sparkles")
                        .primaryButtonStyle()
                }
                .hearthPressStyle(scale: 0.98, pressedOpacity: 0.86)
                .frame(maxWidth: 360)
                .accessibilityIdentifier("pro.locked.upgrade")
            }
            .padding(FilumaSpacing.screen)
        }
    }
}

struct FilumaPaywallView: View {
    let feature: ProFeature

    @Environment(FilumaProStore.self) private var proStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let privacyURL = URL(string: "https://sparkbiscuit.me/privacy/")!
    private let termsURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    var body: some View {
        NavigationStack {
            SubscriptionStoreView(productIDs: FilumaProProduct.all) {
                VStack(spacing: 16) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(Color.brand300)
                        .frame(width: 58, height: 58)
                        .background(Color.brand500.opacity(0.16), in: Circle())
                        .hearthGlow(.brand500, radius: 20, opacity: 0.4)
                        .accessibilityHidden(true)

                    VStack(spacing: 7) {
                        Text(feature.eyebrow)
                            .font(AppFont.caption(12))
                            .foregroundStyle(Color.brand300)
                        Text(feature.title)
                            .font(AppFont.title(27))
                            .foregroundStyle(Color.filumaText)
                            .multilineTextAlignment(.center)
                        Text(feature.message)
                            .font(AppFont.body(14))
                            .foregroundStyle(Color.filumaSubtle)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                    }

                    proBenefits
                }
                .padding(.horizontal, FilumaSpacing.screen)
                .padding(.top, 12)
            }
            .storeButton(.visible, for: .restorePurchases)
            .subscriptionStorePolicyDestination(url: privacyURL, for: .privacyPolicy)
            .subscriptionStorePolicyDestination(url: termsURL, for: .termsOfService)
            .tint(Color.brand500)
            .background {
                HearthScreenBackground(
                    topGlow: 0.24,
                    bottomGlow: 0.32,
                    embers: reduceMotion ? 0 : 12,
                    emberIntensity: 0.72
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("pro.paywall.close")
                }
            }
            .overlay(alignment: .bottom) {
                if CommandLine.arguments.contains("-ui-testing-free") {
                    Button("Simulate Pro for UI testing") {
                        proStore.grantProForUITesting()
                    }
                    .font(AppFont.caption(11))
                    .foregroundStyle(Color.filumaFaint)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("pro.paywall.uiTestPurchase")
                }
            }
            .onChange(of: proStore.isPro) { _, isPro in
                guard isPro else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(FilumaRadius.sheet)
        .accessibilityIdentifier("pro.paywall")
    }

    private var proBenefits: some View {
        VStack(alignment: .leading, spacing: 9) {
            benefit("Unlimited active tasks", icon: "infinity")
            benefit("Apple and Google Calendar integrations", icon: "calendar.badge.clock")
            benefit("Widgets and Live Activities", icon: "rectangle.3.group.fill")
            benefit("Weekly repeats and advanced planning", icon: "arrow.triangle.2.circlepath")
            benefit("Your full two-week Weave", icon: "squareshape.split.3x3")
        }
        .padding(14)
        .background(Color.filumaSurface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FilumaRadius.card, style: .continuous)
                .stroke(Color.filumaBorder)
        }
        .frame(maxWidth: 560)
    }

    private func benefit(_ text: String, icon: String) -> some View {
        Label {
            Text(text)
                .font(AppFont.bodySemibold(13))
                .foregroundStyle(Color.filumaText)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brand300)
                .frame(width: 22)
        }
    }
}

enum ProFeatureSuspension {
    /// Stop off-device Pro integrations after entitlement loss while keeping
    /// authored tasks and already-exported calendar events untouched. Imported
    /// busy-event mirrors are removed so an expired subscription cannot leave a
    /// schedule constrained by calendar data that will no longer refresh.
    @MainActor
    static func reconcileFreeTier(in context: ModelContext) throws {
        guard !FilumaProAccess.isPro else { return }
        let settings = try context.fetch(FetchDescriptor<UserSettings>()).first
        let busyEvents = try context.fetch(FetchDescriptor<BusyEvent>())
        let imported = busyEvents.filter {
            $0.source == .appleCalendar || $0.source == .googleCalendar
        }

        guard settings?.importFromAppleCalendar == true
                || settings?.exportToAppleCalendar == true
                || settings?.importFromGoogleCalendar == true
                || settings?.exportToGoogleCalendar == true
                || !imported.isEmpty else {
            return
        }

        try context.transaction {
            settings?.importFromAppleCalendar = false
            settings?.exportToAppleCalendar = false
            settings?.importFromGoogleCalendar = false
            settings?.exportToGoogleCalendar = false
            settings?.googleSyncToken = nil
            for event in imported { context.delete(event) }
            try context.save()
        }

        PlanCoordinator.publishChange(context: context, interactive: false)
    }
}
