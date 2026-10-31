import Testing
@testable import mvbench

@Test func percentilesInterpolateBetweenRanks() throws {
    let summary = try #require(Summary((1...100).map(Double.init)))
    #expect(summary.count == 100)
    #expect(summary.mean == 50.5)
    #expect(summary.min == 1)
    #expect(summary.max == 100)
    #expect(summary.p50 == 50.5)
    #expect(abs(summary.p95 - 95.05) < 1e-9)
    #expect(abs(summary.p99 - 99.01) < 1e-9)
}

@Test func singleSampleIsEveryPercentile() throws {
    let summary = try #require(Summary([7]))
    #expect(summary.p50 == 7)
    #expect(summary.p99 == 7)
}

@Test func emptySamplesHaveNoSummary() {
    #expect(Summary([]) == nil)
}

@Test func measureRecordsEachRun() {
    var runs = 0
    let durations = Measure.durations(repeat: 5, warmup: 2) { runs += 1 }
    #expect(durations.count == 5)
    #expect(runs == 7)
}

@Test func durationConvertsToMilliseconds() {
    #expect(Duration.milliseconds(1500).milliseconds == 1500)
    #expect(Duration.microseconds(250).milliseconds == 0.25)
}
