<!-- Extracted from https://dart.dev/effective-dart/style. Curated from the canonical Effective Dart guide; verbs (DO / DON'T / PREFER / AVOID / CONSIDER) are preserved verbatim. Project-level overrides live in .claude/rules/dart-discipline.md and take precedence. -->

# Effective Dart: style

**Scope:** Naming, ordering, formatting.

**Precedence:** if a rule here conflicts with `.claude/rules/dart-discipline.md`, the project rules in `dart-discipline.md` win. This file is the broader Dart-community baseline.

---

A surprisingly important part of good code is good style. Consistent naming, ordering, and formatting helps code that *is* the same *look* the same. It takes advantage of the powerful pattern-matching hardware most of us have in our ocular systems. If we use a consistent style across the entire Dart ecosystem, it makes it easier for all of us to learn from and contribute to each others' code.

## Identifiers



Identifiers come in three flavors in Dart.

-

`UpperCamelCase` names capitalize the first letter of each word, including the first.

-

`lowerCamelCase` names capitalize the first letter of each word, *except* the first which is always lowercase, even if it's an acronym.

-

`lowercase_with_underscores` names use only lowercase letters, even for acronyms, and separate words with `_`.

### DO name types using `UpperCamelCase`

 Classes, enum types, typedefs, and type parameters should capitalize the first letter of each word (including the first word), and use no separators.

```dart // good
class SliderMenu {
   ...
}

class HttpRequest {
   ...
}

typedef Predicate<T> = bool Function(T value);
```

This even includes classes intended to be used in metadata annotations.

```dart // good
class Foo {
  const Foo([Object? arg]);
}

@Foo(anArg)
class A {
   ...
}

@Foo()
class B {
   ...
}
```

 If the annotation class's constructor takes no parameters, you might want to create a separate `lowerCamelCase` constant for it.

```dart // good
const foo = Foo();

@foo
class C {
   ...
}
```

### DO name extensions using `UpperCamelCase`

 Like types, [extensions](/language/extension-methods) should capitalize the first letter of each word (including the first word), and use no separators.

```dart // good
extension MyFancyList<T> on List<T> {
   ...
}

extension SmartIterable<T> on Iterable<T> {
   ...
}
```
### DO name packages, directories, and source files using `lowercase_with_underscores`

 Some file systems are not case-sensitive, so many projects require filenames to be all lowercase. Using a separating character allows names to still be readable in that form. Using underscores as the separator ensures that the name is still a valid Dart identifier, which may be helpful if the language later supports symbolic imports.

```dart // good
my_package
└─ lib
   └─ file_system.dart
   └─ slider_menu.dart
```

```dart // bad
mypackage
└─ lib
   └─ file-system.dart
   └─ SliderMenu.dart
```

### DO name import prefixes using `lowercase_with_underscores`

```dart // good
import 'dart:math' as math;
import 'package:angular_components/angular_components.dart' as angular_components;
import 'package:js/js.dart' as js;
```

```dart // bad
import 'dart:math' as Math;
import 'package:angular_components/angular_components.dart' as angularComponents;
import 'package:js/js.dart' as JS;
```

### DO name other identifiers using `lowerCamelCase`

 Class members, top-level definitions, variables, parameters, and named parameters should capitalize the first letter of each word *except* the first word, and use no separators.

```dart // good
var count = 3;

HttpRequest httpRequest;

void align(bool clearItems) {
  // ...
}
```

### PREFER using `lowerCamelCase` for constant names

In new code, use `lowerCamelCase` for constant variables, including enum values.

```dart // good
const pi = 3.14;
const defaultTimeout = 1000;
final urlScheme = RegExp('^([a-z]+):');

class Dice {
  static final numberGenerator = Random();
}
```

```dart // bad
const PI = 3.14;
const DefaultTimeout = 1000;
final URL_SCHEME = RegExp('^([a-z]+):');

class Dice {
  static final NUMBER_GENERATOR = Random();
}
```

 You may use `SCREAMING_CAPS` for consistency with existing code, as in the following cases:

- When adding code to a file or library that already uses `SCREAMING_CAPS`.
-  When generating Dart code that's parallel to Java code—for example, in enumerated types generated from [protobufs.](https://pub.dev/packages/protobuf)

### DO capitalize acronyms and abbreviations longer than two letters like words



 Capitalized acronyms can be hard to read, and multiple adjacent acronyms can lead to ambiguous names. For example, given an identifier `HTTPSFTP`, the reader can't tell if it refers to `HTTPS` `FTP` or `HTTP` `SFTP`. To avoid this, capitalize most acronyms and abbreviations like regular words. This identifier would be `HttpsFtp` if referring to the former or `HttpSftp` for the latter.

 Two-letter abbreviations and acronyms are the exception. If both letters are capitalized in English, then they should both stay capitalized when used in an identifier. Otherwise, capitalize it like a word.

```dart // good
// Longer than two letters, so always like a word:
Http // "hypertext transfer protocol"
Nasa // "national aeronautics and space administration"
Uri // "uniform resource identifier"
Esq // "esquire"
Ave // "avenue"

// Two letters, capitalized in English, so capitalized in an identifier:
ID // "identifier"
TV // "television"
UI // "user interface"

// Two letters, not capitalized in English, so like a word in an identifier:
Mr // "mister"
St // "street"
Rd // "road"
```

```dart // bad
HTTP // "hypertext transfer protocol"
NASA // "national aeronautics and space administration"
URI // "uniform resource identifier"
esq // "esquire"
ave // "avenue"

Id // "identifier"
Tv // "television"
Ui // "user interface"

MR // "mister"
ST // "street"
RD // "road"
```

 When any form of abbreviation comes at the beginning of a `lowerCamelCase` identifier, the abbreviation should be all lowercase:

dart

```dart
var httpConnection = connect();
var tvSet = Television();
var mrRogers = 'hello, neighbor';
```
### PREFER using wildcards for unused callback parameters



 Sometimes the type signature of a callback function requires a parameter, but the callback implementation doesn't *use* the parameter. In this case, it's idiomatic to name the unused parameter `_`, which declares a [wildcard variable](/language/variables#wildcard-variables) that is non-binding.

```dart // good
futureOfVoid.then((_) {
  print('Operation complete.');
});
```

 Because wildcard variables are non-binding, you can name multiple unused parameters `_`.

```dart // good
.onError((_, _) {
  print('Operation failed.');
});
```

 This guideline is only for functions that are both *anonymous and local*. These functions are usually used immediately in a context where it's clear what the unused parameter represents. In contrast, top-level functions and method declarations don't have that context, so their parameters must be named so that it's clear what each parameter is for, even if it isn't used.

### DON'T use a leading underscore for identifiers that aren't private



 Dart uses a leading underscore in an identifier to mark members and top-level declarations as private. This trains users to associate a leading underscore with one of those kinds of declarations. They see "_" and think "private".

 There is no concept of "private" for local variables, parameters, local functions, or library prefixes. When one of those has a name that starts with an underscore, it sends a confusing signal to the reader. To avoid that, don't use leading underscores in those names.

### DON'T use prefix letters



[Hungarian notation](https://en.wikipedia.org/wiki/Hungarian_notation) and other schemes arose in the time of BCPL, when the compiler didn't do much to help you understand your code. Because Dart can tell you the type, scope, mutability, and other properties of your declarations, there's no reason to encode those properties in identifier names.

```dart // good
defaultTimeout
```

```dart // bad
kDefaultTimeout
```

### DON'T explicitly name libraries



 Appending a name to the `library` directive is technically possible, but is a legacy feature and discouraged.

 Dart generates a unique tag for each library based on its path and filename. Naming libraries overrides this generated URI. Without the URI, it can be harder for tools to find the main library file in question.

```dart // bad
library my_library;
```

```dart // good
/// A really great test library.
@TestOn('browser')
library;
```

## Ordering



 To keep the preamble of your file tidy, we have a prescribed order that directives should appear in. Each "section" should be separated by a blank line.

 A single linter rule handles all the ordering guidelines: [directives_ordering.](/tools/linter-rules/directives_ordering)

### DO place `dart:` imports before other imports

```dart // good
import 'dart:async';
import 'dart:collection';

import 'package:bar/bar.dart';
import 'package:foo/foo.dart';
```

### DO place `package:` imports before relative imports

```dart // good
import 'package:bar/bar.dart';
import 'package:foo/foo.dart';

import 'util.dart';
```

### DO specify exports in a separate section after all imports

```dart // good
import 'src/error.dart';
import 'src/foo_bar.dart';

export 'src/error.dart';
```

```dart // bad
import 'src/error.dart';
export 'src/error.dart';
import 'src/foo_bar.dart';
```

### DO sort sections alphabetically

```dart // good
import 'package:bar/bar.dart';
import 'package:foo/foo.dart';

import 'foo.dart';
import 'foo/foo.dart';
```

```dart // bad
import 'package:foo/foo.dart';
import 'package:bar/bar.dart';

import 'foo/foo.dart';
import 'foo.dart';
```

## Formatting



 Like many languages, Dart ignores whitespace. However, *humans* don't. Having a consistent whitespace style helps ensure that human readers see code the same way the compiler does.

### DO format your code using `dart format`



 Formatting is tedious work and is particularly time-consuming during refactoring. Fortunately, you don't have to worry about it. We provide a sophisticated automated code formatter called [`dart format`](/tools/dart-format) that does it for you. The official whitespace-handling rules for Dart are *whatever `dart format` produces*. The [formatter FAQ](https://github.com/dart-lang/dart_style/wiki/FAQ) can provide more insight into the style choices it enforces.

 The remaining formatting guidelines are for the few things `dart format` cannot fix for you.

### CONSIDER changing your code to make it more formatter-friendly



 The formatter does the best it can with whatever code you throw at it, but it can't work miracles. If your code has particularly long identifiers, deeply nested expressions, a mixture of different kinds of operators, etc. the formatted output may still be hard to read.

 When that happens, reorganize or simplify your code. Consider shortening a local variable name or hoisting out an expression into a new local variable. In other words, make the same kinds of modifications that you'd make if you were formatting the code by hand and trying to make it more readable. Think of `dart format` as a partnership where you work together, sometimes iteratively, to produce beautiful code.
### PREFER lines 80 characters or fewer

 Readability studies show that long lines of text are harder to read because your eye has to travel farther when moving to the beginning of the next line. This is why newspapers and magazines use multiple columns of text.

 If you really find yourself wanting lines longer than 80 characters, our experience is that your code is likely too verbose and could be a little more compact. The main offender is usually `VeryLongCamelCaseClassNames`. Ask yourself, "Does each word in that type name tell me something critical or prevent a name collision?" If not, consider omitting it.

 Note that `dart format` defaults to 80 characters or fewer, though you can [configure](/tools/dart-format#page-width) the default. It does not split long string literals to fit in 80 columns, so you have to do that manually.

**Exception:** When a URI or file path occurs in a comment or string (usually in an import or export), it may remain whole even if it causes the line to go over 80 characters. This makes it easier to search source files for a path.

**Exception:** Multi-line strings can contain lines longer than 80 characters because newlines are significant inside the string and splitting the lines into shorter ones can alter the program.
### DO use curly braces for all flow control statements

Doing so avoids the [dangling else](https://en.wikipedia.org/wiki/Dangling_else) problem.

```dart // good
if (isWeekDay) {
  print('Bike to work!');
} else {
  print('Go dancing or read a book!');
}
```

**Exception:** When you have an `if` statement with no `else` clause and the whole `if` statement fits on one line, you can omit the braces if you prefer:

```dart // good
if (arg == null) return defaultValue;
```

If the body wraps to the next line, though, use braces:

```dart // good
if (overflowChars != other.overflowChars) {
  return overflowChars < other.overflowChars;
}
```

```dart // bad
if (overflowChars != other.overflowChars)
  return overflowChars < other.overflowChars;
```

Was this page's content helpful?

Unless stated otherwise, the documentation on this site reflects Dart 3.11.0. Page last updated on 2026-05-12.  [View source](https://github.com/dart-lang/site-www/blob/main/src/content/effective-dart/style.md)  or [report an issue](https://github.com/dart-lang/site-www/issues/new?template=1_page_issue.yml&page-url=https://dart.dev/effective-dart/style&page-source=https://github.com/dart-lang/site-www/blob/main/src/content/effective-dart/style.md).
