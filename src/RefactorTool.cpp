#include "clang/ASTMatchers/ASTMatchFinder.h"
#include "clang/ASTMatchers/ASTMatchers.h"
#include "clang/Basic/AttrKinds.h"
#include "clang/Frontend/FrontendActions.h"
#include "clang/Rewrite/Core/Rewriter.h"
#include "clang/Tooling/CommonOptionsParser.h"
#include "clang/Tooling/Refactoring.h"
#include "clang/Tooling/Tooling.h"
#include "llvm/Support/CommandLine.h"

#include <ranges>
#include <unordered_set>

#include "RefactorTool.h"

using namespace clang;
using namespace clang::ast_matchers;
using namespace clang::tooling;

static llvm::cl::OptionCategory ToolCategory("refactor-tool options");

// Метод run вызывается для каждого совпадения с матчем.
// Мы проверяем тип совпадения по bind-именам и применяем рефакторинг.
void RefactorHandler::run(const MatchFinder::MatchResult &Result) {
    auto &Diag{Result.Context->getDiagnostics()};
    auto &SM{*Result.SourceManager};

    const auto *Dtor{Result.Nodes.getNodeAs<CXXDestructorDecl>("nonVirtualDtor")};
    if (Dtor)
        handle_nv_dtor(Dtor, Diag, SM);

    const auto *Method{Result.Nodes.getNodeAs<CXXMethodDecl>("methodDecl")};
    if (Method) {
        if (Method->size_overridden_methods() > 0 && !Method->hasAttr<OverrideAttr>())
            handle_miss_override(Method, Diag, SM);
    }

    const auto *LoopVar{Result.Nodes.getNodeAs<VarDecl>("loopVar")};
    if (LoopVar)
        handle_crange_for(LoopVar, Diag, SM);
}

// todo: необходимо реализовать обработку случая невиртуального деструктора
void RefactorHandler::handle_nv_dtor(const CXXDestructorDecl *Dtor, DiagnosticsEngine &Diag, SourceManager &SM) {
    if (Dtor->isImplicit())
        return;

    auto Loc{Dtor->getLocation()};
    if (!Loc.isValid() || !SM.isInMainFile(Loc))
        return;

    auto Offset{SM.getFileOffset(Loc)};
    if (virtualDtorLocations.count(Offset))
        return;
    virtualDtorLocations.insert(Offset);

    const auto *Class{Dtor->getParent()};
    if (!Class || !Class->isThisDeclarationADefinition())
        return;

    bool HasDerived{};
    for (const auto &Child : Class->getASTContext().getTranslationUnitDecl()->decls()) {
        const auto *CXXChild{dyn_cast<CXXRecordDecl>(Child)};
        if (CXXChild && CXXChild != Class && CXXChild->isThisDeclarationADefinition()) {
            for (const auto &Base : CXXChild->bases()) {
                const auto *BaseType{Base.getType().getTypePtr()};
                if (const auto *BaseRecord = BaseType->getAsCXXRecordDecl()) {
                    if (BaseRecord->getCanonicalDecl() == Class->getCanonicalDecl()) {
                        HasDerived = true;
                        break;
                    }
                }
            }
            if (HasDerived)
                break;
        }
    }

    if (!HasDerived)
        return;

    Rewrite.InsertTextBefore(Loc, "virtual ");

    const auto DiagID{Diag.getCustomDiagID(DiagnosticsEngine::Remark, "Добавлен 'virtual' к деструктору")};
    Diag.Report(Loc, DiagID);
}

// todo: необходимо реализовать обработку случая отсутствие override
void RefactorHandler::handle_miss_override(const CXXMethodDecl *Method, DiagnosticsEngine &Diag, SourceManager &SM) {
    auto Loc{Method->getLocation()};
    if (!Loc.isValid() || !SM.isInMainFile(Loc))
        return;

    auto Offset{SM.getFileOffset(Loc)};
    if (overrideLocations.count(Offset))
        return;

    overrideLocations.insert(Offset);

    std::string MethodName;
    if (const auto *Dtor = dyn_cast<CXXDestructorDecl>(Method)) {
        MethodName = "~" + Dtor->getParent()->getNameAsString();
    } else {
        MethodName = Method->getNameAsString();
    }

    auto EndLoc{Method->getSourceRange().getEnd()};
    const auto *Ptr{SM.getCharacterData(EndLoc)};
    if (!Ptr)
        return;

    const std::int32_t MAX_INSTRUCTION_LENGTH{256};
    for (auto i : std::views::iota(0, MAX_INSTRUCTION_LENGTH)) {
        if (Ptr - i < SM.getCharacterData(SM.getLocForStartOfFile(SM.getFileID(EndLoc))))
            break;

        if (Ptr[-i] == ')') {
            auto InsertLoc{EndLoc.getLocWithOffset(-i + 1)};
            Rewrite.InsertText(InsertLoc, " override", true);
            Diag.Report(Loc, Diag.getCustomDiagID(DiagnosticsEngine::Remark, "Добавлен 'override' к методу %0"))
                << MethodName;
            return;
        }
    }

    Diag.Report(Loc, Diag.getCustomDiagID(DiagnosticsEngine::Remark, "Не удалось найти ')' для метода %0"))
        << MethodName;
}

// todo: необходимо реализовать обработку случая отсутствие & в range-for
void RefactorHandler::handle_crange_for(const VarDecl *LoopVar, DiagnosticsEngine &Diag, SourceManager &SM) {
    auto VarLoc{LoopVar->getLocation()};

    if (!VarLoc.isValid() || !SM.isInMainFile(VarLoc))
        return;

    auto InsertFailed{Rewrite.InsertText(VarLoc, "&", false)};

    if (InsertFailed) {
        Diag.Report(LoopVar->getLocation(),
                    Diag.getCustomDiagID(DiagnosticsEngine::Error, "Не удалось вставить '&' перед переменной '%0'"))
            << LoopVar->getName();
        return;
    }

    Diag.Report(LoopVar->getLocation(),
                Diag.getCustomDiagID(DiagnosticsEngine::Remark, "Добавлена ссылка '&' к переменной '%0' в range-for"))
        << LoopVar->getName();
}

// todo: ниже необходимо реализовать матчеры для поиска узлов AST
// note: синтаксис написания матчеров точно такой же как и для использования clang-query
/*
    Пример того, как может выглядеть реализация:
    auto AllClassesMatcher()
    {
        return cxxRecordDecl().bind("classDecl");
    }
*/
auto NvDtorMatcher() {
    return cxxDestructorDecl(unless(isVirtual()), unless(isImplicit()), ofClass(cxxRecordDecl(unless(isFinal()))))
        .bind("nonVirtualDtor");
}

auto NoOverrideMatcher() {
    return cxxMethodDecl(isOverride(), unless(isImplicit()), unless(cxxDestructorDecl())).bind("methodDecl");
}

auto NoRefConstVarInRangeLoopMatcher() {
    return cxxForRangeStmt(hasLoopVariable(
        varDecl(hasType(isConstQualified()), unless(hasType(referenceType())), unless(hasType(builtinType())))
            .bind("loopVar")));
}

// Конструктор принимает Rewriter для изменения кода.
ComplexConsumer::ComplexConsumer(Rewriter &Rewrite) : Handler(Rewrite) {
    // Создаем MatchFinder и добавляем матчеры.
    Finder.addMatcher(NvDtorMatcher(), &Handler);
    Finder.addMatcher(NoOverrideMatcher(), &Handler);
    Finder.addMatcher(NoRefConstVarInRangeLoopMatcher(), &Handler);
}

// Метод HandleTranslationUnit вызывается для каждого файла.
void ComplexConsumer::HandleTranslationUnit(ASTContext &Context) { Finder.matchAST(Context); }

std::unique_ptr<ASTConsumer> CodeRefactorAction::CreateASTConsumer(CompilerInstance &CI, StringRef file) {
    RewriterForCodeRefactor.setSourceMgr(CI.getSourceManager(), CI.getLangOpts());
    return std::make_unique<ComplexConsumer>(RewriterForCodeRefactor);
}

bool CodeRefactorAction::BeginSourceFileAction(CompilerInstance &CI) {
    // Инициализируем Rewriter для рефакторинга.
    RewriterForCodeRefactor.setSourceMgr(CI.getSourceManager(), CI.getLangOpts());
    return true;  // Возвращаем true, чтобы продолжить обработку файла.
}

void CodeRefactorAction::EndSourceFileAction() {
    // Применяем изменения в файле.
    if (RewriterForCodeRefactor.overwriteChangedFiles()) {
        llvm::errs() << "Error applying changes to files.\n";
    }
}
