def is_winning_selection(game_type: str, selection: str, dice_value: int) -> bool:
    if game_type == "odd_even":
        return (dice_value % 2 == 1 and selection == "odd") or (dice_value % 2 == 0 and selection == "even")
    if game_type == "under_over":
        return (dice_value <= 3 and selection == "under") or (dice_value >= 4 and selection == "over")
    if game_type == "exact_number":
        return str(dice_value) == selection
    return False
