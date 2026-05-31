import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/features/ai/application/ai_providers_service.dart';

void main() {
  group('AI provider default paths', () {
    test('Gemini defaults match official REST paths', () {
      expect(
        defaultChatPathForType(AIProviderTypes.gemini),
        '/v1beta/{model=models/*}:generateContent',
      );
      expect(
        defaultModelsPathForType(AIProviderTypes.gemini),
        '/v1beta/models',
      );
    });

    test('Anthropic defaults use Messages and Models APIs', () {
      expect(defaultChatPathForType(AIProviderTypes.claude), '/v1/messages');
      expect(defaultModelsPathForType(AIProviderTypes.claude), '/v1/models');
    });
  });
}
