#!/bin/bash

# Test script for EQ functionality
USER_ID="$1"

if [ -z "$USER_ID" ]; then
    echo "Usage: $0 <user_id>"
    echo "Example: $0 123"
    exit 1
fi

BASE_URL="http://localhost:7000"

echo "=== EQ System Test for User ID: $USER_ID ==="
echo

# Test 1: Get current EQ status
echo "1. Getting current EQ status..."
curl -s "${BASE_URL}/eq_preset_${USER_ID}" | python3 -m json.tool
echo -e "\n"

# Test 2: Change to different presets
presets=("pop" "rock" "classical" "bass_heavy" "bright" "flat")

for preset in "${presets[@]}"; do
    echo "2. Changing EQ preset to: $preset"
    curl -s -X POST "${BASE_URL}/eq_preset_${USER_ID}?preset=$preset" | python3 -m json.tool
    echo -e "\n"
    sleep 2
done

# Test 3: Test invalid preset
echo "3. Testing invalid preset (should fail)..."
curl -s -X POST "${BASE_URL}/eq_preset_${USER_ID}?preset=invalid" | python3 -m json.tool
echo -e "\n"

# Test 4: Final status check
echo "4. Final EQ status check..."
curl -s "${BASE_URL}/eq_preset_${USER_ID}" | python3 -m json.tool
echo -e "\n"

echo "=== EQ Test Complete ==="
