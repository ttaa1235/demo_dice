export const GAME_TYPES = ["odd_even", "under_over", "exact_number"] as const;

export type GameType = (typeof GAME_TYPES)[number];

export const GAME_LABELS: Record<GameType, string> = {
  odd_even: "홀짝",
  under_over: "언더오버",
  exact_number: "숫자적중"
};

export const SELECTION_LABELS: Record<string, string> = {
  odd: "홀",
  even: "짝",
  under: "언더 1-3",
  over: "오버 4-6",
  "1": "1",
  "2": "2",
  "3": "3",
  "4": "4",
  "5": "5",
  "6": "6"
};
