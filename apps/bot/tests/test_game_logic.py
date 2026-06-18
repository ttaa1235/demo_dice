import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from game_logic import is_winning_selection


class GameLogicTest(unittest.TestCase):
    def test_odd_even_selection(self) -> None:
        self.assertTrue(is_winning_selection("odd_even", "odd", 1))
        self.assertTrue(is_winning_selection("odd_even", "even", 6))
        self.assertFalse(is_winning_selection("odd_even", "odd", 2))

    def test_under_over_selection(self) -> None:
        self.assertTrue(is_winning_selection("under_over", "under", 3))
        self.assertTrue(is_winning_selection("under_over", "over", 4))
        self.assertFalse(is_winning_selection("under_over", "over", 2))

    def test_exact_number_selection(self) -> None:
        self.assertTrue(is_winning_selection("exact_number", "5", 5))
        self.assertFalse(is_winning_selection("exact_number", "5", 6))


if __name__ == "__main__":
    unittest.main()
