import Testing
@testable import NotchCapabilities

@Test("Force Click rungs need clearly separate pressure to fire")
func forceClickRungsHaveDistinctThresholds() {
    let baseline: Float = 100

    #expect(ForceClickPressurePolicy.progress(for: .light, pressure: 180, baseline: baseline) == 1)
    #expect(ForceClickPressurePolicy.progress(for: .medium, pressure: 180, baseline: baseline) < 1)
    #expect(ForceClickPressurePolicy.progress(for: .medium, pressure: 300, baseline: baseline) == 1)
    #expect(ForceClickPressurePolicy.progress(for: .firm, pressure: 300, baseline: baseline) < 1)
    #expect(ForceClickPressurePolicy.progress(for: .firm, pressure: 420, baseline: baseline) == 1)
}

@Test("a higher first-click baseline keeps the Force Click rungs distinct")
func forceClickRungsAdaptToTheFirstClick() {
    let baseline: Float = 160

    #expect(ForceClickPressurePolicy.progress(for: .light, pressure: 232, baseline: baseline) == 1)
    #expect(ForceClickPressurePolicy.progress(for: .medium, pressure: 300, baseline: baseline) < 1)
    #expect(ForceClickPressurePolicy.progress(for: .medium, pressure: 344, baseline: baseline) == 1)
    #expect(ForceClickPressurePolicy.progress(for: .firm, pressure: 420, baseline: baseline) < 1)
    #expect(ForceClickPressurePolicy.progress(for: .firm, pressure: 464, baseline: baseline) == 1)
}
