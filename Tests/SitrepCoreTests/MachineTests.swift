import Foundation
import Testing
@testable import SitrepCore

/// These assert against the real machine rather than a fixture. The sysctl
/// bridge is the thing under test; mocking it would test nothing.
@Suite("Machine identity")
struct MachineTests {

    @Test("Resolves hardware identity from sysctl")
    func readsHardwareIdentity() {
        let machine = Machine.current()

        #expect(!machine.hardwareModel.isEmpty)
        #expect(machine.hardwareModel != "unknown", "hw.model should resolve on any Mac")
        #expect(machine.cpuBrand != "unknown", "machdep.cpu.brand_string should resolve")
        #expect(machine.osBuild != "unknown", "kern.osversion should resolve")
    }

    @Test("Reports plausible memory and core counts")
    func reportsPlausibleMemoryAndCores() {
        let machine = Machine.current()

        // 1 GiB floor rules out a zeroed read; 1 TiB ceiling rules out a
        // width or endianness mistake in Sysctl.integer.
        #expect(machine.physicalMemoryBytes > 1_073_741_824)
        #expect(machine.physicalMemoryBytes < 1_099_511_627_776)

        #expect(machine.coreCount > 0)
        #expect(machine.coreCount < 1024)
    }

    @Test("Memory size agrees with Foundation")
    func memorySizeMatchesFoundation() {
        // Cross-checks the sysctl path against a completely independent source.
        // A mismatch means Sysctl.integer is misreading widths.
        #expect(Machine.current().physicalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
    }

    @Test("Summary names the machine it describes")
    func summaryIncludesIdentifyingFields() {
        let machine = Machine.current()
        let summary = machine.summary

        #expect(summary.contains(machine.hardwareModel))
        #expect(summary.contains(machine.cpuBrand))
        #expect(summary.contains(machine.osBuild))
    }

    @Test("Round-trips through JSON unchanged")
    func roundTripsThroughJSON() throws {
        // Profile artifacts are JSON and are the published source of truth,
        // so Machine must survive a round trip exactly.
        let original = Machine.current()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Machine.self, from: data)

        #expect(original == decoded)
    }
}

@Suite("Sysctl bridge")
struct SysctlTests {

    @Test("Returns nil for unknown keys")
    func returnsNilForUnknownKeys() {
        #expect(Sysctl.string("this.key.does.not.exist") == nil)
        #expect(Sysctl.integer("this.key.does.not.exist", as: UInt64.self) == nil)
    }

    @Test("Reads integer keys at both kernel widths")
    func readsKnownIntegerKeysAtBothWidths() {
        // hw.memsize is 64-bit, hw.logicalcpu is 32-bit — both branches of
        // Sysctl.integer must work.
        #expect(Sysctl.integer("hw.memsize", as: UInt64.self) != nil)
        #expect(Sysctl.integer("hw.logicalcpu", as: Int.self) != nil)
    }

    @Test("Declines struct-valued keys rather than returning garbage")
    func declinesStructValuedKeys() {
        // vm.swapusage is a struct, not an integer. Milestone 2 reads it
        // properly; until then Sysctl.integer must refuse it.
        #expect(Sysctl.integer("vm.swapusage", as: UInt64.self) == nil)
    }

    @Test("Reads known string keys")
    func readsKnownStringKeys() {
        #expect(Sysctl.string("hw.model") != nil)
        #expect(Sysctl.string("kern.ostype") == "Darwin")
    }
}
