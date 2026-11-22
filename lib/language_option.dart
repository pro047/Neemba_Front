class TargetLanguageOption {
  final String label;
  final String translationCode;
  final String ttsLocale;

  const TargetLanguageOption({
    required this.label,
    required this.translationCode,
    required this.ttsLocale,
  });
}

const englishTargetLanguage = TargetLanguageOption(
  label: 'English',
  translationCode: 'en-US',
  ttsLocale: 'en-US',
);

const swahiliTargetLanguage = TargetLanguageOption(
  label: 'Swahili',
  translationCode: 'SW',
  ttsLocale: 'sw-KE',
);

const targetLanguageOptions = <TargetLanguageOption>[
  englishTargetLanguage,
  swahiliTargetLanguage,
];

TargetLanguageOption targetLanguageOptionForCode(String translationCode) {
  return targetLanguageOptions.firstWhere(
    (option) => option.translationCode == translationCode,
    orElse: () => englishTargetLanguage,
  );
}
