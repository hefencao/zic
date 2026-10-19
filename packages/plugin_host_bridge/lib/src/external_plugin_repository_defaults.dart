// Repository shortcuts are development conveniences. Product builds require
// users to supply their own indexes and contain no bundled repository URLs.
const defaultMihonExtensionRepository = bool.fromEnvironment('dart.vm.product')
    ? ''
    : 'https://github.com/keiyoushi/extensions/raw/repo/index.pb';
const defaultVeneraSourceRepository = bool.fromEnvironment('dart.vm.product')
    ? ''
    : 'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json';
