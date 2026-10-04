import Foundation

@main
struct DesignFontPolicyChecks {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        // Default must retain every system size, including the accessibility range.
        for category in 0...11 {
            expect(YimaFontScalePolicy.appCategory(system: category, preference: nil) == category,
                   "Default must follow the system, rather than force Large")
        }
        // Retain the legacy App preference category while the system uses ordinary sizes.
        for preference in [1, 2, 4, 5, 6] {
            expect(YimaFontScalePolicy.appCategory(system: 3, preference: preference) == preference,
                   "A saved App size must preserve its category mapping")
            expect(YimaFontScalePolicy.appCategory(system: 9, preference: preference) == 9,
                   "A saved small App size must not reduce accessibility3")
        }
        expect(YimaFontScalePolicy.contentMultiplier(0.88, system: 3) == 0.88,
               "Ordinary reading sizes retain the independent small preference")
        expect(YimaFontScalePolicy.contentMultiplier(0.88, system: 7) == 1,
               "Accessibility text must not shrink below the system size")
        expect(YimaFontScalePolicy.contentMultiplier(1.21, system: 9) == 1.21,
               "A larger reading preference remains available at accessibility3")
        print("Design font policy checks passed")
    }
}
