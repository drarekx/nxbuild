import Testing
@testable import NXBuild

@MainActor
struct DockProgressTests {
    @Test func overallFraction() {
        #expect(DockProgress.overall(stage: 0, of: 5, frac: nil) == nil)          // aún sin etapas
        #expect(DockProgress.overall(stage: 1, of: 4, frac: nil) == 0)            // primera etapa sin cuenta
        #expect(DockProgress.overall(stage: 3, of: 4, frac: 0.5) == 0.625)        // 2 hechas + media
        #expect(DockProgress.overall(stage: 4, of: 4, frac: 1) == 1)
    }
}
