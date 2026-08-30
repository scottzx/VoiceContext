import SwiftUI
import StoreKit

struct PurchaseUnlockView: View {
    @Bindable var trial: TrialEntitlementController
    @State private var isPresentingOfferCodeSheet = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(trial.isUnlocked ? "已永久解锁" : trial.remainingTimeText)
                        .font(.headline)
                    ProgressView(value: trial.isUnlocked ? 1 : trial.progressFraction)
                        .tint(trial.isPurchaseLocked ? .orange : .accentColor)
                    Text(trial.availabilityCaption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("这是一次性永久解锁，不是订阅。无业务服务器。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            if !trial.isUnlocked {
                Section {
                    Button {
                        Task { await trial.purchase() }
                    } label: {
                        if trial.isBusy {
                            ProgressView()
                        } else {
                            Text(purchaseButtonTitle)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trial.isBusy)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Button("恢复购买") {
                        Task { await trial.restore() }
                    }
                    .disabled(trial.isBusy)

                    Button("兑换优惠码") {
                        isPresentingOfferCodeSheet = true
                    }
                    .disabled(trial.isBusy)
                } footer: {
                    Text("支持输入 App Store 兑换码直接解锁；原始录音文件保存在设备本机，可通过系统「文件」App 查阅与导出。")
                }
            }

            if let statusMessage = trial.statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("条款与隐私") {
                Link(destination: URL(string: "https://scottzx.github.io/voicecontext-site/privacy.html")!) {
                    Label("隐私政策", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://scottzx.github.io/voicecontext-site/terms.html")!) {
                    Label("使用条款", systemImage: "doc.text")
                }
            }

            #if DEBUG
            Section("开发测试") {
                Button("重置 3 天试用倒计时") {
                    trial.resetTrialForTesting()
                }
                Button("模拟试用到期") {
                    trial.simulateExhaustionForTesting()
                }
            }
            #endif
        }
        .navigationTitle("试用与永久解锁")
        .navigationBarTitleDisplayMode(.inline)
        .offerCodeRedemption(isPresented: $isPresentingOfferCodeSheet) { result in
            Task {
                await trial.refreshFromStore()
            }
        }
        .task {
            trial.start()
            trial.noteAppBecameActive()
            await trial.refreshFromStore()
        }
    }

    private var purchaseButtonTitle: String {
        if let displayPrice = trial.displayPrice, !displayPrice.isEmpty {
            return "永久解锁 · \(displayPrice)"
        }
        return "永久解锁"
    }
}

/// Full-screen paywall presented immediately when the 72-hour trial expires.
struct ExpiredPaywallView: View {
    @Bindable var trial: TrialEntitlementController
    @State private var isPresentingOfferCodeSheet = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)
                        .padding(.top, 12)

                    Text("72 小时试用已到期")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text("一次性永久解锁 VoiceContext 全部功能（本地端侧 AI 转写、说话人识别与会议整理）。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .padding(.bottom, 8)
            }

            Section("数据安全说明") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder.badge.person.crop")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("录音数据完整保存在本机")
                            .font(.subheadline.weight(.semibold))
                        Text("您的原始音频与文稿完全储存在设备本地，不会丢失。在系统自带的「文件」App（我的 iPhone → VoiceContext）中可随时查阅与备份。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    Task { await trial.purchase() }
                } label: {
                    if trial.isBusy {
                        ProgressView()
                    } else {
                        Text(purchaseButtonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trial.isBusy)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                Button("恢复购买") {
                    Task { await trial.restore() }
                }
                .disabled(trial.isBusy)

                Button("兑换优惠码") {
                    isPresentingOfferCodeSheet = true
                }
                .disabled(trial.isBusy)
            } footer: {
                Text("这是一次性永久解锁，不是订阅。无业务服务器，100% 本地端侧隐私安全。")
            }

            if let statusMessage = trial.statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("条款与隐私") {
                Link(destination: URL(string: "https://scottzx.github.io/voicecontext-site/privacy.html")!) {
                    Label("隐私政策", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://scottzx.github.io/voicecontext-site/terms.html")!) {
                    Label("使用条款", systemImage: "doc.text")
                }
            }

            #if DEBUG
            Section("开发测试") {
                Button("重置 3 天试用倒计时") {
                    trial.resetTrialForTesting()
                }
                Button("模拟试用到期") {
                    trial.simulateExhaustionForTesting()
                }
            }
            #endif
        }
        .navigationTitle("永久解锁")
        .navigationBarTitleDisplayMode(.inline)
        .offerCodeRedemption(isPresented: $isPresentingOfferCodeSheet) { _ in
            Task {
                await trial.refreshFromStore()
            }
        }
        .task {
            trial.start()
            trial.noteAppBecameActive()
            await trial.refreshFromStore()
        }
    }

    private var purchaseButtonTitle: String {
        if let displayPrice = trial.displayPrice, !displayPrice.isEmpty {
            return "永久解锁 · \(displayPrice)"
        }
        return "永久解锁"
    }
}

struct TrialQuotaSettingsSection: View {
    @Bindable var trial: TrialEntitlementController

    var body: some View {
        Section("转写试用") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(trial.isUnlocked ? "已永久解锁" : trial.remainingTimeText)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if trial.isPurchaseLocked {
                        Text("待解锁")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    } else if !trial.isUnlocked, trial.progressFraction >= 0.9 {
                        Text("即将到期")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                ProgressView(value: trial.isUnlocked ? 1 : trial.progressFraction)
                Text(trial.availabilityCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            NavigationLink {
                PurchaseUnlockView(trial: trial)
            } label: {
                Label("试用与永久解锁", systemImage: "lock.open")
            }
        }
    }
}
