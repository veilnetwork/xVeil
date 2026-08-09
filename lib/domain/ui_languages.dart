// The names the language picker shows, and the order it shows them in.
//
// Every language is named in ITSELF — "Deutsch", not "German". That is the
// convention every multilingual product converges on, and here it is also what
// makes the feature scale: a translated list would need each language's name in
// every other language, so N languages would cost N² names on top of the 1751
// strings each one already needs. An endonym costs one string, forever, and is
// the one label a person looking for their own language can actually find.
//
// Nothing here is generated from the locale: `Locale.languageCode` gives a code,
// and Flutter has no endonym table. A missing entry is not a failure — the code
// itself is shown, which is ugly but honest and never blocks shipping a
// translation.

/// Native name for a language code (`ru` → `Русский`).
///
/// Keyed by the bare language subtag. Script/region variants are listed in full
/// where they are genuinely different written languages a person picks between
/// (`zh-Hans` vs `zh-Hant`) and not otherwise: `pt-BR` and `pt` are one entry
/// until someone ships both.
String languageEndonym(String code) => _endonyms[code] ?? _endonyms[_base(code)] ?? code;

/// Whether this build knows a native name for [code] — the picker still lists
/// unknown languages, so this exists for tests and for the localisation
/// tooling, not to gate the UI.
bool hasEndonym(String code) =>
    _endonyms.containsKey(code) || _endonyms.containsKey(_base(code));

String _base(String code) => code.split(RegExp('[-_]')).first;

/// Languages written right-to-left. The app must flip its whole layout for
/// these, so the list is load-bearing rather than cosmetic.
const Set<String> _rtl = {'ar', 'fa', 'he', 'ur', 'ps', 'sd', 'ug', 'yi', 'dv'};

/// Does this language read right-to-left?
bool isRtlLanguage(String code) => _rtl.contains(_base(code));

/// The picker's order: by the endonym, not by the code.
///
/// Sorted by the NAME SHOWN, because that is the order the list appears to be
/// in — sorted by invisible codes it reads as unsorted.
///
/// The comparison is Dart's, which orders by UTF-16 code unit and not by any
/// locale's collation (Dart ships no collator). In practice that groups each
/// script together — Latin, then Cyrillic, then CJK — which is a defensible
/// order for a list nobody reads end to end, and it is stable and testable.
/// A reader looking for their own language finds it by its script long before
/// they would find it alphabetically.
List<String> sortedByEndonym(Iterable<String> codes) {
  final out = codes.toList()
    ..sort((a, b) => languageEndonym(a).toLowerCase().compareTo(
      languageEndonym(b).toLowerCase(),
    ));
  return out;
}

/// Native names. Ordered by speakers, roughly, so the list is easy to extend
/// downward — the UI sorts by name, so the order here is for maintainers.
const Map<String, String> _endonyms = {
  'en': 'English',
  'zh': '中文',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁體中文',
  'hi': 'हिन्दी',
  'es': 'Español',
  'ar': 'العربية',
  'bn': 'বাংলা',
  'pt': 'Português',
  'ru': 'Русский',
  'ja': '日本語',
  'pa': 'ਪੰਜਾਬੀ',
  'de': 'Deutsch',
  'jv': 'Basa Jawa',
  'ko': '한국어',
  'fr': 'Français',
  'te': 'తెలుగు',
  'mr': 'मराठी',
  'tr': 'Türkçe',
  'ta': 'தமிழ்',
  'vi': 'Tiếng Việt',
  'ur': 'اردو',
  'it': 'Italiano',
  'th': 'ไทย',
  'gu': 'ગુજરાતી',
  'fa': 'فارسی',
  'pl': 'Polski',
  'uk': 'Українська',
  'ml': 'മലയാളം',
  'kn': 'ಕನ್ನಡ',
  'my': 'မြန်မာ',
  'or': 'ଓଡ଼ିଆ',
  'su': 'Basa Sunda',
  'ro': 'Română',
  'az': 'Azərbaycan',
  'nl': 'Nederlands',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'el': 'Ελληνικά',
  'hu': 'Magyar',
  'cs': 'Čeština',
  'sv': 'Svenska',
  'he': 'עברית',
  'da': 'Dansk',
  'fi': 'Suomi',
  'no': 'Norsk',
  'nb': 'Norsk bokmål',
  'sk': 'Slovenčina',
  'bg': 'Български',
  'sr': 'Српски',
  'hr': 'Hrvatski',
  'sl': 'Slovenščina',
  'lt': 'Lietuvių',
  'lv': 'Latviešu',
  'et': 'Eesti',
  'ka': 'ქართული',
  'hy': 'Հայերեն',
  'kk': 'Қазақша',
  'uz': 'Oʻzbekcha',
  'ky': 'Кыргызча',
  'tg': 'Тоҷикӣ',
  'be': 'Беларуская',
  'sq': 'Shqip',
  'mk': 'Македонски',
  'bs': 'Bosanski',
  'is': 'Íslenska',
  'ga': 'Gaeilge',
  'cy': 'Cymraeg',
  'eu': 'Euskara',
  'ca': 'Català',
  'gl': 'Galego',
  'af': 'Afrikaans',
  'sw': 'Kiswahili',
  'am': 'አማርኛ',
  'ha': 'Hausa',
  'yo': 'Yorùbá',
  'ig': 'Igbo',
  'zu': 'isiZulu',
  'xh': 'isiXhosa',
  'so': 'Soomaali',
  'ne': 'नेपाली',
  'si': 'සිංහල',
  'km': 'ភាសាខ្មែរ',
  'lo': 'ລາວ',
  'mn': 'Монгол',
  'ps': 'پښتو',
  'ku': 'Kurdî',
  'sd': 'سنڌي',
  'as': 'অসমীয়া',
  'mi': 'Te Reo Māori',
  'haw': 'ʻŌlelo Hawaiʻi',
  'tl': 'Tagalog',
  'ceb': 'Cebuano',
  'mg': 'Malagasy',
  'ny': 'Chichewa',
  'sn': 'chiShona',
  'st': 'Sesotho',
  'tt': 'Татарча',
  'ba': 'Башҡортса',
  'cv': 'Чӑвашла',
  'yi': 'ייִדיש',
  'lb': 'Lëtzebuergesch',
  'mt': 'Malti',
  'fo': 'Føroyskt',
  'eo': 'Esperanto',
  'la': 'Latina',
  'dv': 'ދިވެހި',
  'ug': 'ئۇيغۇرچە',
  'bo': 'བོད་སྐད',
  'ti': 'ትግርኛ',
  'om': 'Afaan Oromoo',
  'rw': 'Ikinyarwanda',
  'lg': 'Luganda',
  'wo': 'Wolof',
  'ff': 'Fulfulde',
  'bm': 'Bamanankan',
  'ak': 'Akan',
  'tw': 'Twi',
  'ee': 'Eʋegbe',
  'gn': 'Guaraní',
  'qu': 'Runa Simi',
  'ay': 'Aymar aru',
  'ht': 'Kreyòl ayisyen',
  'sm': 'Gagana Samoa',
  'to': 'Lea faka-Tonga',
  'fj': 'Na Vosa Vakaviti',
};
