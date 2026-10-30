<!-- Extracted from https://dart.dev/effective-dart. Defines the meaning of DO / DON'T / PREFER / AVOID / CONSIDER and the shared glossary used by the four sibling guides. -->

# Effective Dart: overview

**Scope:** the canonical definitions of the five guideline verbs (DO / DON'T / PREFER / AVOID / CONSIDER) and the Dart terminology glossary.

**Precedence:** if a rule in the sibling guides conflicts with `.claude/rules/dart-discipline.md`, the project rules win. This page does not define rules of its own — it explains how to read the others.

---

Over the past several years, we've written a ton of Dart code and learned a lot about what works well and what doesn't. We're sharing this with you so you can write consistent, robust, fast code too. There are two overarching themes:

1.

**Be consistent.** When it comes to things like formatting, and casing, arguments about which is better are subjective and impossible to resolve. What we do know is that being *consistent* is objectively helpful.

If two pieces of code look different it should be because they *are* different in some meaningful way. When a bit of code stands out and catches your eye, it should do so for a useful reason.

2.

**Be brief.** Dart was designed to be familiar, so it inherits many of the same statements and expressions as C, Java, JavaScript and other languages. But we created Dart because there is a lot of room to improve on what those languages offer. We added a bunch of features, from string interpolation to initializing formals, to help you express your intent more simply and easily.

If there are multiple ways to say something, you should generally pick the most concise one. This is not to say you should [code golf](https://en.wikipedia.org/wiki/Code_golf) yourself into cramming a whole program into a single line. The goal is code that is *economical*, not *dense*.

## The guides



We split the guidelines into a few separate pages for easy digestion:

-

**[Style Guide](/effective-dart/style)** – This defines the rules for laying out and organizing code, or at least the parts that [`dart format`](/tools/dart-format) doesn't handle for you. The style guide also specifies how identifiers are formatted: `camelCase`, `using_underscores`, etc.

-

**[Documentation Guide](/effective-dart/documentation)** – This tells you everything you need to know about what goes inside comments. Both doc comments and regular, run-of-the-mill code comments.

-

**[Usage Guide](/effective-dart/usage)** – This teaches you how to make the best use of language features to implement behavior. If it's in a statement or expression, it's covered here.

-

**[Design Guide](/effective-dart/design)** – This is the softest guide, but the one with the widest scope. It covers what we've learned about designing consistent, usable APIs for libraries. If it's in a type signature or declaration, this goes over it.

 For links to all the guidelines, see the [summary](#summary-of-all-rules).

## How to read the guides



 Each guide is broken into a few sections. Sections contain a list of guidelines. Each guideline starts with one of these words:

-

**DO** guidelines describe practices that should always be followed. There will almost never be a valid reason to stray from them.

-

**DON'T** guidelines are the converse: things that are almost never a good idea. Hopefully, we don't have as many of these as other languages do because we have less historical baggage.

-

**PREFER** guidelines are practices that you *should* follow. However, there may be circumstances where it makes sense to do otherwise. Just make sure you understand the full implications of ignoring the guideline when you do.

-

**AVOID** guidelines are the dual to "prefer": stuff you shouldn't do but where there may be good reasons to on rare occasions.

-

**CONSIDER** guidelines are practices that you might or might not want to follow, depending on circumstances, precedents, and your own preference.

 Some guidelines describe an **exception** where the rule does *not* apply. When listed, the exceptions may not be exhaustive—you might still need to use your judgement on other cases.

 This sounds like the police are going to beat down your door if you don't have your laces tied correctly. Things aren't that bad. Most of the guidelines here are common sense and we're all reasonable people. The goal, as always, is nice, readable and maintainable code.

 The Dart analyzer provides a linter to help you write good, consistent code that follows these and other guidelines. If one or more [linter rules](/tools/linter-rules) exist that can help you follow a guideline then the guideline links to those rules. The links use the following format:

 To learn how to use the linter, see [Enabling linter rules](/tools/analysis#enabling-linter-rules) and the list of [linter rules](/tools/linter-rules).

## Glossary



 To keep the guidelines brief, we use a few shorthand terms to refer to different Dart constructs.

-

A **library member** is a top-level field, getter, setter, or function. Basically, anything at the top level that isn't a type.

-

A **class member** is a constructor, field, getter, setter, function, or operator declared inside a class. Class members can be instance or static, abstract or concrete.

-

A **member** is either a library member or a class member.

-

A **variable**, when used generally, refers to top-level variables, parameters, and local variables. It doesn't include static or instance fields.

-

A **type** is any named type declaration: a class, typedef, or enum.

-

A **property** is a top-level variable, getter (inside a class or at the top level, instance or static), setter (same), or field (instance or static). Roughly any "field-like" named construct.

## Summary of all rules



### Style



**Identifiers**

-  [DO name types using `UpperCamelCase`.](/effective-dart/style#do-name-types-using-uppercamelcase)
-  [DO name extensions using `UpperCamelCase`.](/effective-dart/style#do-name-extensions-using-uppercamelcase)
-  [DO name packages, directories, and source files using `lowercase_with_underscores`.](/effective-dart/style#do-name-packages-and-file-system-entities-using-lowercase-with-underscores)
-  [DO name import prefixes using `lowercase_with_underscores`.](/effective-dart/style#do-name-import-prefixes-using-lowercase_with_underscores)
-  [DO name other identifiers using `lowerCamelCase`.](/effective-dart/style#do-name-other-identifiers-using-lowercamelcase)
-  [PREFER using `lowerCamelCase` for constant names.](/effective-dart/style#prefer-using-lowercamelcase-for-constant-names)
-  [DO capitalize acronyms and abbreviations longer than two letters like words.](/effective-dart/style#do-capitalize-acronyms-and-abbreviations-longer-than-two-letters-like-words)
-  [PREFER using wildcards for unused callback parameters.](/effective-dart/style#prefer-using-wildcards-for-unused-callback-parameters)
-  [DON'T use a leading underscore for identifiers that aren't private.](/effective-dart/style#dont-use-a-leading-underscore-for-identifiers-that-arent-private)
- [DON'T use prefix letters.](/effective-dart/style#dont-use-prefix-letters)
- [DON'T explicitly name libraries.](/effective-dart/style#dont-explicitly-name-libraries)

**Ordering**

-  [DO place `dart:` imports before other imports.](/effective-dart/style#do-place-dart-imports-before-other-imports)
-  [DO place `package:` imports before relative imports.](/effective-dart/style#do-place-package-imports-before-relative-imports)
-  [DO specify exports in a separate section after all imports.](/effective-dart/style#do-specify-exports-in-a-separate-section-after-all-imports)
- [DO sort sections alphabetically.](/effective-dart/style#do-sort-sections-alphabetically)

**Formatting**

-  [DO format your code using `dart format`.](/effective-dart/style#do-format-your-code-using-dart-format)
-  [CONSIDER changing your code to make it more formatter-friendly.](/effective-dart/style#consider-changing-your-code-to-make-it-more-formatter-friendly)
-  [PREFER lines 80 characters or fewer.](/effective-dart/style#prefer-lines-80-characters-or-fewer)
-  [DO use curly braces for all flow control statements.](/effective-dart/style#do-use-curly-braces-for-all-flow-control-statements)

### Documentation



**Comments**

-  [DO format comments like sentences.](/effective-dart/documentation#do-format-comments-like-sentences)
-  [DON'T use block comments for documentation.](/effective-dart/documentation#dont-use-block-comments-for-documentation)

**Doc comments**

-  [DO use `///` doc comments to document members and types.](/effective-dart/documentation#do-use-doc-comments-to-document-members-and-types)
-  [PREFER writing doc comments for public APIs.](/effective-dart/documentation#prefer-writing-doc-comments-for-public-apis)
-  [CONSIDER writing a library-level doc comment.](/effective-dart/documentation#consider-writing-a-library-level-doc-comment)
-  [CONSIDER writing doc comments for private APIs.](/effective-dart/documentation#consider-writing-doc-comments-for-private-apis)
-  [DO start doc comments with a single-sentence summary.](/effective-dart/documentation#do-start-doc-comments-with-a-single-sentence-summary)
-  [DO separate the first sentence of a doc comment into its own paragraph.](/effective-dart/documentation#do-separate-the-first-sentence-of-a-doc-comment-into-its-own-paragraph)
-  [AVOID redundancy with the surrounding context.](/effective-dart/documentation#avoid-redundancy-with-the-surrounding-context)
-  [PREFER starting comments of a function or method with third-person verbs if its main purpose is a side effect.](/effective-dart/documentation#prefer-starting-comments-of-a-function-or-method-with-third-person-verbs-if-its-main-purpose-is-a-side-effect)
-  [PREFER starting a non-boolean variable or property comment with a noun phrase.](/effective-dart/documentation#prefer-starting-a-non-boolean-variable-or-property-comment-with-a-noun-phrase)
-  [PREFER starting a boolean variable or property comment with "Whether" followed by a noun or gerund phrase.](/effective-dart/documentation#prefer-starting-a-boolean-variable-or-property-comment-with-whether-followed-by-a-noun-or-gerund-phrase)
-  [PREFER a noun phrase or non-imperative verb phrase for a function or method if returning a value is its primary purpose.](/effective-dart/documentation#prefer-a-noun-phrase-or-non-imperative-verb-phrase-for-a-function-or-method-if-returning-a-value-is-its-primary-purpose)
-  [DON'T write documentation for both the getter and setter of a property.](/effective-dart/documentation#dont-write-documentation-for-both-the-getter-and-setter-of-a-property)
-  [PREFER starting library or type comments with noun phrases.](/effective-dart/documentation#prefer-starting-library-or-type-comments-with-noun-phrases)
-  [CONSIDER including code samples in doc comments.](/effective-dart/documentation#consider-including-code-samples-in-doc-comments)
-  [DO use square brackets in doc comments to refer to in-scope identifiers.](/effective-dart/documentation#do-use-square-brackets-in-doc-comments-to-refer-to-in-scope-identifiers)
-  [DO use prose to explain parameters, return values, and exceptions.](/effective-dart/documentation#do-use-prose-to-explain-parameters-return-values-and-exceptions)
-  [DO put doc comments before metadata annotations.](/effective-dart/documentation#do-put-doc-comments-before-metadata-annotations)

**Markdown**

-  [AVOID using markdown excessively.](/effective-dart/documentation#avoid-using-markdown-excessively)
-  [AVOID using HTML for formatting.](/effective-dart/documentation#avoid-using-html-for-formatting)
-  [PREFER backtick fences for code blocks.](/effective-dart/documentation#prefer-backtick-fences-for-code-blocks)

**Writing**

- [PREFER brevity.](/effective-dart/documentation#prefer-brevity)
-  [AVOID abbreviations and acronyms unless they are obvious.](/effective-dart/documentation#avoid-abbreviations-and-acronyms-unless-they-are-obvious)
-  [PREFER using "this" instead of "the" to refer to a member's instance.](/effective-dart/documentation#prefer-using-this-instead-of-the-to-refer-to-a-members-instance)

### Usage



**Libraries**

-  [DO use strings in `part of` directives.](/effective-dart/usage#do-use-strings-in-part-of-directives)
-  [DON'T import libraries that are inside the `src` directory of another package.](/effective-dart/usage#dont-import-libraries-that-are-inside-the-src-directory-of-another-package)
-  [DON'T allow an import path to reach into or out of `lib`.](/effective-dart/usage#dont-allow-an-import-path-to-reach-into-or-out-of-lib)
- [PREFER relative import paths.](/effective-dart/usage#prefer-relative-import-paths)

**Null**

-  [DON'T explicitly initialize variables to `null`.](/effective-dart/usage#dont-explicitly-initialize-variables-to-null)
-  [DON'T use an explicit default value of `null`.](/effective-dart/usage#dont-use-an-explicit-default-value-of-null)
-  [DON'T use `true` or `false` in equality operations.](/effective-dart/usage#dont-use-true-or-false-in-equality-operations)
-  [AVOID `late` variables if you need to check whether they are initialized.](/effective-dart/usage#avoid-late-variables-if-you-need-to-check-whether-they-are-initialized)
-  [CONSIDER type promotion or null-check patterns for using nullable types.](/effective-dart/usage#consider-type-promotion-or-null-check-patterns-for-using-nullable-types)

**Strings**

-  [DO use adjacent strings to concatenate string literals.](/effective-dart/usage#do-use-adjacent-strings-to-concatenate-string-literals)
-  [PREFER using interpolation to compose strings and values.](/effective-dart/usage#prefer-using-interpolation-to-compose-strings-and-values)
-  [AVOID using curly braces in interpolation when not needed.](/effective-dart/usage#avoid-using-curly-braces-in-interpolation-when-not-needed)

**Collections**

-  [DO use collection literals when possible.](/effective-dart/usage#do-use-collection-literals-when-possible)
-  [DON'T use `.length` to see if a collection is empty.](/effective-dart/usage#dont-use-length-to-see-if-a-collection-is-empty)
-  [AVOID using `Iterable.forEach()` with a function literal.](/effective-dart/usage#avoid-using-iterable-foreach-with-a-function-literal)
-  [DON'T use `List.from()` unless you intend to change the type of the result.](/effective-dart/usage#dont-use-list-from-unless-you-intend-to-change-the-type-of-the-result)
-  [DO use `whereType()` to filter a collection by type.](/effective-dart/usage#do-use-wheretype-to-filter-a-collection-by-type)
-  [DON'T use `cast()` when a nearby operation will do.](/effective-dart/usage#dont-use-cast-when-a-nearby-operation-will-do)
- [AVOID using `cast()`.](/effective-dart/usage#avoid-using-cast)

**Functions**

-  [DO use a function declaration to bind a function to a name.](/effective-dart/usage#do-use-a-function-declaration-to-bind-a-function-to-a-name)
-  [DON'T create a lambda when a tear-off will do.](/effective-dart/usage#dont-create-a-lambda-when-a-tear-off-will-do)

**Variables**

-  [DO follow a consistent rule for `var` and `final` on local variables.](/effective-dart/usage#do-follow-a-consistent-rule-for-var-and-final-on-local-variables)
-  [AVOID storing what you can calculate.](/effective-dart/usage#avoid-storing-what-you-can-calculate)

**Members**

-  [DON'T wrap a field in a getter and setter unnecessarily.](/effective-dart/usage#dont-wrap-a-field-in-a-getter-and-setter-unnecessarily)
-  [PREFER using a `final` field to make a read-only property.](/effective-dart/usage#prefer-using-a-final-field-to-make-a-read-only-property)
-  [CONSIDER using `=>` for simple members.](/effective-dart/usage#consider-using-for-simple-members)
-  [DON'T use `this.` except to redirect to a named constructor or to avoid shadowing.](/effective-dart/usage#dont-use-this-when-not-needed-to-avoid-shadowing)
-  [DO initialize fields at their declaration when possible.](/effective-dart/usage#do-initialize-fields-at-their-declaration-when-possible)

**Constructors**

-  [DO use initializing formals when possible.](/effective-dart/usage#do-use-initializing-formals-when-possible)
-  [DON'T use `late` when a constructor initializer list will do.](/effective-dart/usage#dont-use-late-when-a-constructor-initializer-list-will-do)
-  [DO use `;` instead of `{}` for empty constructor bodies.](/effective-dart/usage#do-use-instead-of-for-empty-constructor-bodies)
- [DON'T use `new`.](/effective-dart/usage#dont-use-new)
-  [DON'T use `const` redundantly.](/effective-dart/usage#dont-use-const-redundantly)

**Error handling**

-  [AVOID catches without `on` clauses.](/effective-dart/usage#avoid-catches-without-on-clauses)
-  [DON'T discard errors from catches without `on` clauses.](/effective-dart/usage#dont-discard-errors-from-catches-without-on-clauses)
-  [DO throw objects that implement `Error` only for programmatic errors.](/effective-dart/usage#do-throw-objects-that-implement-error-only-for-programmatic-errors)
-  [DON'T explicitly catch `Error` or types that implement it.](/effective-dart/usage#dont-explicitly-catch-error-or-types-that-implement-it)
-  [DO use `rethrow` to rethrow a caught exception.](/effective-dart/usage#do-use-rethrow-to-rethrow-a-caught-exception)

**Asynchrony**

-  [PREFER async/await over using raw futures.](/effective-dart/usage#prefer-asyncawait-over-using-raw-futures)
-  [DON'T use `async` when it has no useful effect.](/effective-dart/usage#dont-use-async-when-it-has-no-useful-effect)
-  [CONSIDER using higher-order methods to transform a stream.](/effective-dart/usage#consider-using-higher-order-methods-to-transform-a-stream)
- [AVOID using Completer directly.](/effective-dart/usage#avoid-using-completer-directly)
-  [DO test for `Future<T>` when disambiguating a `FutureOr<T>` whose type argument could be `Object`.](/effective-dart/usage#do-test-for-futuret-when-disambiguating-a-futureort-whose-type-argument-could-be-object)

### Design



**Names**

- [DO use terms consistently.](/effective-dart/design#do-use-terms-consistently)
- [AVOID abbreviations.](/effective-dart/design#avoid-abbreviations)
-  [PREFER putting the most descriptive noun last.](/effective-dart/design#prefer-putting-the-most-descriptive-noun-last)
-  [CONSIDER making the code read like a sentence.](/effective-dart/design#consider-making-the-code-read-like-a-sentence)
-  [PREFER a noun phrase for a non-boolean property or variable.](/effective-dart/design#prefer-a-noun-phrase-for-a-non-boolean-property-or-variable)
-  [PREFER a non-imperative verb phrase for a boolean property or variable.](/effective-dart/design#prefer-a-non-imperative-verb-phrase-for-a-boolean-property-or-variable)
-  [CONSIDER omitting the verb for a named boolean *parameter*.](/effective-dart/design#consider-omitting-the-verb-for-a-named-boolean-parameter)
-  [PREFER the "positive" name for a boolean property or variable.](/effective-dart/design#prefer-the-positive-name-for-a-boolean-property-or-variable)
-  [PREFER an imperative verb phrase for a function or method whose main purpose is a side effect.](/effective-dart/design#prefer-an-imperative-verb-phrase-for-a-function-or-method-whose-main-purpose-is-a-side-effect)
-  [PREFER a noun phrase or non-imperative verb phrase for a function or method if returning a value is its primary purpose.](/effective-dart/design#prefer-a-noun-phrase-or-non-imperative-verb-phrase-for-a-function-or-method-if-returning-a-value-is-its-primary-purpose)
-  [CONSIDER an imperative verb phrase for a function or method if you want to draw attention to the work it performs.](/effective-dart/design#consider-an-imperative-verb-phrase-for-a-function-or-method-if-you-want-to-draw-attention-to-the-work-it-performs)
-  [AVOID starting a method name with `get`.](/effective-dart/design#avoid-starting-a-method-name-with-get)
-  [PREFER naming a method `to___()` if it copies the object's state to a new object.](/effective-dart/design#prefer-naming-a-method-to___-if-it-copies-the-objects-state-to-a-new-object)
-  [PREFER naming a method `as___()` if it returns a different representation backed by the original object.](/effective-dart/design#prefer-naming-a-method-as___-if-it-returns-a-different-representation-backed-by-the-original-object)
-  [AVOID describing the parameters in the function's or method's name.](/effective-dart/design#avoid-describing-the-parameters-in-the-functions-or-methods-name)
-  [DO follow existing mnemonic conventions when naming type parameters.](/effective-dart/design#do-follow-existing-mnemonic-conventions-when-naming-type-parameters)

**Libraries**

-  [PREFER making declarations private.](/effective-dart/design#prefer-making-declarations-private)
-  [CONSIDER declaring multiple classes in the same library.](/effective-dart/design#consider-declaring-multiple-classes-in-the-same-library)

**Classes and mixins**

-  [AVOID defining a one-member abstract class when a simple function will do.](/effective-dart/design#avoid-defining-a-one-member-abstract-class-when-a-simple-function-will-do)
-  [AVOID defining a class that contains only static members.](/effective-dart/design#avoid-defining-a-class-that-contains-only-static-members)
-  [AVOID extending a class that isn't intended to be subclassed.](/effective-dart/design#avoid-extending-a-class-that-isnt-intended-to-be-subclassed)
-  [DO use class modifiers to control if your class can be extended.](/effective-dart/design#do-use-class-modifiers-to-control-if-your-class-can-be-extended)
-  [AVOID implementing a class that isn't intended to be an interface.](/effective-dart/design#avoid-implementing-a-class-that-isnt-intended-to-be-an-interface)
-  [DO use class modifiers to control if your class can be an interface.](/effective-dart/design#do-use-class-modifiers-to-control-if-your-class-can-be-an-interface)
-  [PREFER defining a pure `mixin` or pure `class` to a `mixin class`.](/effective-dart/design#prefer-defining-a-pure-mixin-or-pure-class-to-a-mixin-class)

**Constructors**

-  [CONSIDER making your constructor `const` if the class supports it.](/effective-dart/design#consider-making-your-constructor-const-if-the-class-supports-it)

**Members**

-  [PREFER making fields and top-level variables `final`.](/effective-dart/design#prefer-making-fields-and-top-level-variables-final)
-  [DO use getters for operations that conceptually access properties.](/effective-dart/design#do-use-getters-for-operations-that-conceptually-access-properties)
-  [DO use setters for operations that conceptually change properties.](/effective-dart/design#do-use-setters-for-operations-that-conceptually-change-properties)
-  [DON'T define a setter without a corresponding getter.](/effective-dart/design#dont-define-a-setter-without-a-corresponding-getter)
-  [AVOID using runtime type tests to fake overloading.](/effective-dart/design#avoid-using-runtime-type-tests-to-fake-overloading)
-  [AVOID public `late final` fields without initializers.](/effective-dart/design#avoid-public-late-final-fields-without-initializers)
-  [AVOID returning nullable `Future`, `Stream`, and collection types.](/effective-dart/design#avoid-returning-nullable-future-stream-and-collection-types)
-  [AVOID returning `this` from methods just to enable a fluent interface.](/effective-dart/design#avoid-returning-this-from-methods-just-to-enable-a-fluent-interface)

**Types**

-  [DO type annotate variables without initializers.](/effective-dart/design#do-type-annotate-variables-without-initializers)
-  [DO type annotate fields and top-level variables if the type isn't obvious.](/effective-dart/design#do-type-annotate-fields-and-top-level-variables-if-the-type-isnt-obvious)
-  [DON'T redundantly type annotate initialized local variables.](/effective-dart/design#dont-redundantly-type-annotate-initialized-local-variables)
-  [DO annotate return types on function declarations.](/effective-dart/design#do-annotate-return-types-on-function-declarations)
-  [DO annotate parameter types on function declarations.](/effective-dart/design#do-annotate-parameter-types-on-function-declarations)
-  [DON'T annotate inferred parameter types on function expressions.](/effective-dart/design#dont-annotate-inferred-parameter-types-on-function-expressions)
-  [DON'T type annotate initializing formals.](/effective-dart/design#dont-type-annotate-initializing-formals)
-  [DO write type arguments on generic invocations that aren't inferred.](/effective-dart/design#do-write-type-arguments-on-generic-invocations-that-arent-inferred)
-  [DON'T write type arguments on generic invocations that are inferred.](/effective-dart/design#dont-write-type-arguments-on-generic-invocations-that-are-inferred)
-  [AVOID writing incomplete generic types.](/effective-dart/design#avoid-writing-incomplete-generic-types)
-  [DO annotate with `dynamic` instead of letting inference fail.](/effective-dart/design#do-annotate-with-dynamic-instead-of-letting-inference-fail)
-  [PREFER signatures in function type annotations.](/effective-dart/design#prefer-signatures-in-function-type-annotations)
-  [DON'T specify a return type for a setter.](/effective-dart/design#dont-specify-a-return-type-for-a-setter)
-  [DON'T use the legacy typedef syntax.](/effective-dart/design#dont-use-the-legacy-typedef-syntax)
-  [PREFER inline function types over typedefs.](/effective-dart/design#prefer-inline-function-types-over-typedefs)
-  [PREFER using function type syntax for parameters.](/effective-dart/design#prefer-using-function-type-syntax-for-parameters)
-  [AVOID using `dynamic` unless you want to disable static checking.](/effective-dart/design#avoid-using-dynamic-unless-you-want-to-disable-static-checking)
-  [DO use `Future<void>` as the return type of asynchronous members that do not produce values.](/effective-dart/design#do-use-futurevoid-as-the-return-type-of-asynchronous-members-that-do-not-produce-values)
-  [AVOID using `FutureOr<T>` as a return type.](/effective-dart/design#avoid-using-futureort-as-a-return-type)

**Parameters**

-  [AVOID positional boolean parameters.](/effective-dart/design#avoid-positional-boolean-parameters)
-  [AVOID optional positional parameters if the user may want to omit earlier parameters.](/effective-dart/design#avoid-optional-positional-parameters-if-the-user-may-want-to-omit-earlier-parameters)
-  [AVOID mandatory parameters that accept a special "no argument" value.](/effective-dart/design#avoid-mandatory-parameters-that-accept-a-special-no-argument-value)
-  [DO use inclusive start and exclusive end parameters to accept a range.](/effective-dart/design#do-use-inclusive-start-and-exclusive-end-parameters-to-accept-a-range)

**Equality**

-  [DO override `hashCode` if you override `==`.](/effective-dart/design#do-override-hashcode-if-you-override)
-  [DO make your `==` operator obey the mathematical rules of equality.](/effective-dart/design#do-make-your-operator-obey-the-mathematical-rules-of-equality)
-  [AVOID defining custom equality for mutable classes.](/effective-dart/design#avoid-defining-custom-equality-for-mutable-classes)
-  [DON'T make the parameter to `==` nullable.](/effective-dart/design#dont-make-the-parameter-to-nullable)

Was this page's content helpful?

Unless stated otherwise, the documentation on this site reflects Dart 3.11.0. Page last updated on 2025-09-04.  [View source](https://github.com/dart-lang/site-www/blob/main/src/content/effective-dart/index.md)  or [report an issue](https://github.com/dart-lang/site-www/issues/new?template=1_page_issue.yml&page-url=https://dart.dev/effective-dart&page-source=https://github.com/dart-lang/site-www/blob/main/src/content/effective-dart/index.md).
