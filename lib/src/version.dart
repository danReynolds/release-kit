/// The version of the rk program.
///
/// A compiled CLI cannot read the pubspec that produced it. Keep this literal
/// in library code so both the composition root and the stage identity use the
/// same value; real-process tests freeze its agreement with pubspec.yaml.
const rkVersion = '0.1.3';
