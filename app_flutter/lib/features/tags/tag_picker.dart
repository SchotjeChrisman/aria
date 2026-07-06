/// The tag picker was hoisted to lib/widgets so every feature's context
/// menus can assign tags; this shim keeps feature-local imports working.
library;

export '../../widgets/tag_picker.dart';
