/// The version of the rk program.
///
/// A compiled CLI cannot read the pubspec that produced it. Keep this literal
/// in library code so `rk --version`, `rk target` and the installation manager
/// report the same value; real-process tests freeze its agreement with
/// pubspec.yaml.
const rkVersion = '0.1.14';
