import { useAtomSet, useAtomValue } from "@effect/atom-react";
import { AsyncResult } from "effect/reactivity";
import { useEffect, useState } from "react";
import { Keyboard, View } from "react-native";

import { AppText as Text, AppTextInput } from "../../../components/AppText";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../../state/preferences";
import {
  deleteWhisperApiKey,
  loadWhisperApiKey,
  saveWhisperApiKey,
} from "../../voice-input/whisperTranscription";
import { SettingsActionRow } from "./SettingsActionRow";
import { SettingsChoiceRow } from "./SettingsChoiceRow";
import { SettingsSection } from "./SettingsSection";

/** The key stays in Keychain; preferences contain only the selected transcription provider. */
export function VoiceTranscriptionSettings() {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const ready = AsyncResult.isSuccess(preferences) && !preferences.waiting;
  const selected = AsyncResult.isSuccess(preferences)
    ? (preferences.value.voiceTranscriptionProvider ?? "apple")
    : null;
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [key, setKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    void loadWhisperApiKey().then(
      (value) => {
        if (active) setHasKey(Boolean(value?.trim()));
      },
      () => {
        if (active) setError("Could not read the saved API key. Reopen this screen to try again.");
      },
    );
    return () => {
      active = false;
    };
  }, []);

  const updateKey = async (remove: boolean) => {
    Keyboard.dismiss();
    setBusy(true);
    setError(null);
    try {
      if (remove) await deleteWhisperApiKey();
      else await saveWhisperApiKey(key);
      setHasKey(!remove);
      setKey("");
    } catch {
      setError(
        remove
          ? "Could not delete the API key. Try again."
          : "Could not save the API key. Try again.",
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <SettingsSection title="Transcription">
        <SettingsChoiceRow
          label="Apple"
          description="On-device transcription using your device language."
          selected={selected === "apple"}
          disabled={!ready}
          onPress={() => savePreferences({ voiceTranscriptionProvider: "apple" })}
        />
        <SettingsChoiceRow
          label="OpenAI Whisper (experimental)"
          description="Automatically detects languages, including mixed Polish and English."
          selected={selected === "whisper"}
          separated
          disabled={!ready}
          onPress={() => savePreferences({ voiceTranscriptionProvider: "whisper" })}
        />
      </SettingsSection>
      {selected === "whisper" ? (
        <>
          <SettingsSection title="OpenAI API key">
            <View className="gap-3 px-4 pt-4">
              <Text className="text-sm text-foreground-muted">
                {hasKey === null
                  ? "Checking Keychain…"
                  : hasKey
                    ? "API key saved on this device."
                    : "No API key saved."}
              </Text>
              <AppTextInput
                accessibilityLabel="OpenAI API key"
                placeholder={hasKey ? "Enter a replacement API key" : "Enter your OpenAI API key"}
                value={key}
                onChangeText={setKey}
                secureTextEntry
                autoCapitalize="none"
                autoCorrect={false}
                autoComplete="off"
                textContentType="none"
                editable={!busy}
              />
            </View>
            <SettingsActionRow
              icon="checkmark"
              label={hasKey ? "Replace API key" : "Save API key"}
              disabled={busy || !key.trim()}
              loading={busy}
              onPress={() => void updateKey(false)}
            />
            {hasKey ? (
              <SettingsActionRow
                icon="trash"
                label="Delete API key"
                tone="danger"
                disabled={busy}
                onPress={() => void updateKey(true)}
              />
            ) : null}
          </SettingsSection>
          <Text className="px-2 text-sm text-foreground-muted">
            Recordings are sent directly to OpenAI for transcription. API usage is billed separately
            from ChatGPT. Your key is stored in this iPhone’s Keychain.
          </Text>
          {error ? (
            <Text accessibilityRole="alert" className="px-2 text-sm text-danger-foreground">
              {error}
            </Text>
          ) : null}
        </>
      ) : null}
    </>
  );
}
