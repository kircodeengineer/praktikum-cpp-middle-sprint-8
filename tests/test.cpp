#include <gtest/gtest.h>

#include "RefactorTool.h"
#include "clang/Rewrite/Core/Rewriter.h"
#include "clang/Tooling/Tooling.h"

using namespace clang;
using namespace clang::tooling;
using namespace testing;
using namespace std::literals;

class CodeRefactorTestAction : public CodeRefactorAction {
public:
    explicit CodeRefactorTestAction(std::string &OutputBuffer) : Output(OutputBuffer) {}

    void EndSourceFileAction() override {
        const auto &SourceMgr{RewriterForCodeRefactor.getSourceMgr()};
        auto MainFileID{SourceMgr.getMainFileID()};
        const auto &EditBuffer{RewriterForCodeRefactor.getEditBuffer(MainFileID)};
        Output.assign(EditBuffer.begin(), EditBuffer.end());
    }

private:
    std::string &Output;
};

static std::string applyRefactoring(const std::string &Code) {
    std::string Result{};
    auto Action{std::make_unique<CodeRefactorTestAction>(Result)};
    const auto Success{runToolOnCodeWithArgs(std::move(Action), Code, {"-std=c++23", "-xc++"})};
    EXPECT_TRUE(Success) << "Ошибка при запуске инструмента на коде:\n"s << Code;
    return Result;
}

#define EXPECT_REFACTORING(Input, Expected) EXPECT_EQ(applyRefactoring(Input), Expected)

#define EXPECT_UNCHANGED(Code) EXPECT_EQ(applyRefactoring(Code), Code)

TEST(VirtualDestructorRefactoringTest, AddsVirtualToNonVirtualDtorWithDerivedClass) {
    const auto *Input{R"cpp(
class Base {
    ~Base() {}
};
class Derived : public Base {};
)cpp"};

    const auto *Expected{R"cpp(
class Base {
    virtual ~Base() {}
};
class Derived : public Base {};
)cpp"};

    EXPECT_REFACTORING(Input, Expected);
}

TEST(VirtualDestructorRefactoringTest, NoVirtualIfNoDerivedClass) {
    const auto *Code{R"cpp(
class Standalone {
    ~Standalone() {}
};
)cpp"};

    EXPECT_UNCHANGED(Code);
}

TEST(OverrideRefactoringTest, AddsOverrideToOverridingMethod) {
    const auto *Input{R"cpp(
class Base {
public:
    virtual void foo();
};
class Derived : public Base {
public:
    void foo();
};
)cpp"};

    const auto *Expected{R"cpp(
class Base {
public:
    virtual void foo();
};
class Derived : public Base {
public:
    void foo() override;
};
)cpp"};

    EXPECT_REFACTORING(Input, Expected);
}

TEST(OverrideRefactoringTest, NoOverrideIfAlreadyPresent) {
    const auto *Code{R"cpp(
class Base {
public:
    virtual void bar();
};
class Derived : public Base {
public:
    void bar() override;
};
)cpp"};

    EXPECT_UNCHANGED(Code);
}

TEST(RangeForRefactoringTest, AddsReferenceToConstNonRefLoopVar) {
    const auto *Input{R"cpp(
#include <vector>
void f() {
    const std::vector<int> vec = {1, 2, 3};
    for (const auto v : vec) {}
}
)cpp"};

    const auto *Expected{R"cpp(
#include <vector>
void f() {
    const std::vector<int> vec = {1, 2, 3};
    for (const auto &v : vec) {}
}
)cpp"};

    EXPECT_REFACTORING(Input, Expected);
}

TEST(RangeForRefactoringTest, NoRefIfAlreadyReference) {
    const auto *Code{R"cpp(
#include <vector>
void f() {
    const std::vector<int> vec = {1, 2, 3};
    for (const auto& v : vec) {}
}
)cpp"};

    EXPECT_UNCHANGED(Code);
}

TEST(RefactoringSafetyTest, NoVirtualForImplicitDtor) {
    const auto *Code{R"cpp(
class Base {};
class Derived : public Base {};
)cpp"};

    EXPECT_UNCHANGED(Code);
}

TEST(RefactoringSafetyTest, DoesNotAddOverrideToDestructor) {
    const auto *Code{R"cpp(
class Base {
    virtual ~Base();
};
class Derived : public Base {
    ~Derived();
};
)cpp"};

    EXPECT_UNCHANGED(Code);
}
