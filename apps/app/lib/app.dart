/// Test and embedding facade for the full application composition.
///
/// The executable entrypoint keeps this library in a post-raster deferred
/// loading unit; callers that construct [App] directly can import this facade.
export 'app_runtime.dart' show App;
