import Foundation
import Testing

@testable import CoreKit

@Suite("AppError")
struct AppErrorTests {
    @Test("every case has a non-empty description")
    func descriptions() {
        let cases: [AppError] = [
            .cancelled,
            .unauthorized("token expired"),
            .network("timeout"),
            .decoding("bad JSON"),
            .notFound("plugin"),
            .invalidInput("negative count"),
            .plugin("manifest rejected"),
            .storage("disk full"),
            .unknown("")
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
        }
    }

    @Test("codes are stable identifiers")
    func codes() {
        #expect(AppError.cancelled.code == "cancelled")
        #expect(AppError.plugin("x").code == "plugin")
        #expect(AppError.unknown("x").code == "unknown")
    }

    @Test("equatable ignores nothing")
    func equality() {
        #expect(AppError.network("a") == AppError.network("a"))
        #expect(AppError.network("a") != AppError.network("b"))
        #expect(AppError.network("a") != AppError.storage("a"))
    }
}

@Suite("FeatureFlag")
struct FeatureFlagTests {
    @Test("optional subsystems default off")
    func defaults() {
        #expect(FeatureFlag.pluginMarketplace.defaultEnabled)
        #expect(!FeatureFlag.cloudSync.defaultEnabled)
        #expect(!FeatureFlag.experimentalAgentLoop.defaultEnabled)
    }

    @Test("every flag has a title")
    func titles() {
        for flag in FeatureFlag.allCases {
            #expect(!flag.title.isEmpty)
        }
    }
}

@Suite("DependencyContainer")
struct DependencyContainerTests {
    @Test("live enables only default flags")
    func liveDefaults() {
        let container = DependencyContainer.live
        #expect(container.isEnabled(.pluginMarketplace))
        #expect(!container.isEnabled(.cloudSync))
    }

    @Test("test configuration enables every flag")
    func testEnablesAll() {
        let container = DependencyContainer.test
        for flag in FeatureFlag.allCases {
            #expect(container.isEnabled(flag))
        }
    }

    @Test("module logger keeps the requested category")
    func loggerCategory() {
        let container = DependencyContainer.preview
        #expect(container.logger("NetworkKit").category == "NetworkKit")
    }
}

@Suite("Clock")
struct ClockTests {
    @Test("fixed clock advances deterministically")
    func fixedClock() async throws {
        let clock = FixedClock(Date(timeIntervalSince1970: 100))
        #expect(clock.now == Date(timeIntervalSince1970: 100))
        clock.advance(by: 5)
        #expect(clock.now == Date(timeIntervalSince1970: 105))
        try await clock.sleep(seconds: 2)
        #expect(clock.now == Date(timeIntervalSince1970: 107))
    }
}