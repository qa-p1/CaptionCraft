/// Stable owner used for projects created by desktop builds that do not have
/// Firebase configured. Keeping this value stable lets a Windows installation
/// reopen its local project library across launches without pretending that a
/// cloud account exists.
const String localDesktopOwnerUid = 'captioncraft-local-desktop';
