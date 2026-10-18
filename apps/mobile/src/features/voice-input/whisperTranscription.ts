import * as SecureStore from "expo-secure-store";
import { File } from "expo-file-system";
import { fetch } from "expo/fetch";

import {
  VoiceTranscriptionError,
  throwIfVoiceTranscriptionAborted,
  type VoiceTranscriber,
} from "@t3tools/client-runtime/voice-input";

import { watchNative } from "../watch/native";

const API_KEY_STORAGE_KEY = "t3code.voice-input.openai-api-key";

// Serialize migration with edits so a concurrent read cannot restore a replaced/deleted key.
let keyOperation: Promise<unknown> = Promise.resolve();
function withKeyStorage<T>(operation: () => Promise<T>): Promise<T> {
  const result = keyOperation.then(operation);
  keyOperation = result.catch(() => {});
  return result;
}
const keyOptions = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY };
const refreshWatch = () => {
  void watchNative?.refreshTranscription?.().catch(() => {});
};

export const loadWhisperApiKey = () =>
  withKeyStorage(async () => {
    const key = await SecureStore.getItemAsync(API_KEY_STORAGE_KEY);
    // Existing iOS-only keys used WHEN_UNLOCKED; migrate them on the next successful read.
    if (key) await SecureStore.setItemAsync(API_KEY_STORAGE_KEY, key, keyOptions);
    return key;
  });

export const saveWhisperApiKey = (key: string) =>
  withKeyStorage(async () => {
    await SecureStore.setItemAsync(API_KEY_STORAGE_KEY, key.trim(), keyOptions);
    refreshWatch();
  });

export const deleteWhisperApiKey = () =>
  withKeyStorage(async () => {
    await SecureStore.deleteItemAsync(API_KEY_STORAGE_KEY);
    refreshWatch();
  });

function transcriptionFailure(status: number): string {
  if (status === 401) return "OpenAI rejected the API key. Update it in Settings → Microphone.";
  if (status === 429)
    return "OpenAI's usage limit was reached. Check your API credits and try again.";
  if (status === 413) return "This recording is too large for Whisper. Try a shorter recording.";
  return "Whisper could not transcribe this recording. Try again.";
}

/** Captures the key before recording so settings changes affect only the next session. */
export const whisperTranscriber: VoiceTranscriber = {
  async prepare({ signal }) {
    throwIfVoiceTranscriptionAborted(signal);
    let key: string | null;
    try {
      key = await loadWhisperApiKey();
    } catch {
      throwIfVoiceTranscriptionAborted(signal);
      throw new VoiceTranscriptionError(
        "preparation-failed",
        "Could not read the Whisper API key.",
      );
    }
    throwIfVoiceTranscriptionAborted(signal);
    if (!key?.trim()) {
      throw new VoiceTranscriptionError(
        "preparation-failed",
        "Add your OpenAI API key in Settings → Microphone before using Whisper.",
      );
    }
    const apiKey = key.trim();
    return {
      // Used only by the composer for insertion spacing, never sent to OpenAI.
      locale: Intl.DateTimeFormat().resolvedOptions().locale,
      async transcribe(uri, { signal }) {
        throwIfVoiceTranscriptionAborted(signal);
        const body = new FormData();
        // Expo fetch requires a File/Blob; React Native URI descriptors fail before upload.
        body.append("file", new File(uri));
        body.append("model", "whisper-1");
        body.append("response_format", "json");
        // Leave language and prompt unset to allow automatic detection and mixed languages.
        try {
          const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
            method: "POST",
            headers: { Authorization: `Bearer ${apiKey}` },
            body,
            signal,
          });
          throwIfVoiceTranscriptionAborted(signal);
          if (!response.ok) {
            throw new VoiceTranscriptionError(
              "transcription-failed",
              transcriptionFailure(response.status),
            );
          }
          const result: unknown = await response.json();
          throwIfVoiceTranscriptionAborted(signal);
          if (
            typeof result !== "object" ||
            result === null ||
            !("text" in result) ||
            typeof result.text !== "string"
          ) {
            throw new VoiceTranscriptionError(
              "transcription-failed",
              "Whisper returned an invalid transcript.",
            );
          }
          return result.text.trim();
        } catch (error) {
          throwIfVoiceTranscriptionAborted(signal);
          if (error instanceof VoiceTranscriptionError) throw error;
          throw new VoiceTranscriptionError(
            "transcription-failed",
            "Could not reach Whisper. Check your connection and try again.",
          );
        }
      },
    };
  },
};
