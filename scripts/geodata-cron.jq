def fail($message): error($message);

def ascii_space:
  . == 9 or . == 10 or . == 11 or . == 12 or . == 13 or . == 32;

def ascii_digit:
  . >= 48 and . <= 57;

def numeric_text:
  type == "string" and length > 0 and (explode | all(.[]; ascii_digit));

def words:
  explode |
  map(if ascii_space then 32 else . end) |
  implode |
  split(" ") |
  map(select(length > 0));

def leading_digits:
  explode as $codes |
  ($codes | length) as $length |
  ([range(0; $length) | select(($codes[.] | ascii_digit) | not)][0] // $length);

def number_or_name($value; $names):
  if $value | numeric_text then
    $value | tonumber
  elif $names != null and $names[($value | ascii_downcase)] != null then
    $names[($value | ascii_downcase)]
  else
    fail("invalid cron value: " + $value)
  end;

def cron_field($raw; $minimum; $maximum; $names):
  reduce ($raw | split(",")[]) as $expression
    ({values: [], star: false};
      if $expression == "" then fail("empty cron expression") else . end |
      ($expression | split("/")) as $stepped |
      if ($stepped | length) < 1 or ($stepped | length) > 2 then
        fail("invalid cron step: " + $expression)
      else . end |
      (if ($stepped | length) == 2 then
         if $stepped[1] | numeric_text then $stepped[1] | tonumber
         else fail("invalid cron step: " + $expression)
         end
       else 1 end) as $step |
      if $step < 1 then fail("cron step must be positive: " + $expression) else . end |
      ($stepped[0] == "*" or $stepped[0] == "?") as $wildcard |
      ($stepped[0] | split("-")) as $range |
      if ($range | length) > 2 then fail("invalid cron range: " + $expression) else . end |
      (if $wildcard then $minimum else number_or_name($range[0]; $names) end) as $start |
      (if $wildcard then $maximum
       elif ($range | length) == 2 then number_or_name($range[1]; $names)
       elif ($stepped | length) == 2 then $maximum
       else $start end) as $end |
      if $start < $minimum or $end > $maximum or $start > $end then
        fail("cron range is out of bounds: " + $expression)
      else . end |
      .values += [range($start; $end + 1; $step)] |
      .star = (.star or ($wildcard and $step == 1))) |
  .values |= unique;

def duration_values:
  if length == 0 then []
  else
    . as $raw |
    ($raw | leading_digits) as $whole_length |
    if $whole_length == 0 then fail("invalid @every duration")
    else
      ($raw[$whole_length:] |
       if startswith(".") then
         (.[1:] | leading_digits) as $fraction_length |
         if $fraction_length == 0 then fail("invalid @every duration")
         else $whole_length + 1 + $fraction_length end
       else $whole_length end) as $amount_length |
      ($raw[0:$amount_length] | tonumber) as $amount |
      ($raw[$amount_length:]) as $suffix |
      (if ($suffix | startswith("ns")) then {scale:0.000000001,rest:$suffix[2:]}
       elif ($suffix | startswith("us")) then {scale:0.000001,rest:$suffix[2:]}
       elif ($suffix | startswith("ms")) then {scale:0.001,rest:$suffix[2:]}
       elif ($suffix | startswith("s")) then {scale:1,rest:$suffix[1:]}
       elif ($suffix | startswith("m")) then {scale:60,rest:$suffix[1:]}
       elif ($suffix | startswith("h")) then {scale:3600,rest:$suffix[1:]}
       else fail("invalid @every duration") end) as $unit |
      [($amount * $unit.scale)] + ($unit.rest | duration_values)
    end
  end;

def duration_seconds($raw):
  if ($raw | type) != "string" or ($raw | length) == 0 then fail("invalid @every duration")
  else
    ($raw | duration_values | add // 0) as $seconds |
    if $seconds < 1 then 1 else $seconds | floor end
  end;

def normalize_descriptor($raw):
  if $raw == "@yearly" or $raw == "@annually" then "0 0 1 1 *"
  elif $raw == "@monthly" then "0 0 1 * *"
  elif $raw == "@weekly" then "0 0 * * 0"
  elif $raw == "@daily" or $raw == "@midnight" then "0 0 * * *"
  elif $raw == "@hourly" then "0 * * * *"
  else $raw
  end;

def pseudo_time($parts):
  [$parts[0], $parts[1], $parts[2], $parts[3], $parts[4], $parts[5], 0, 0] | mktime;

def contains_value($field; $value):
  $field.values | index($value) != null;

($spec | normalize_descriptor(.)) as $normalized |
if $normalized | startswith("@every ") then
  (duration_seconds($normalized[7:])) as $delay |
  {due: (($now - $since) >= $delay), normalized: $normalized}
else
  ($normalized | words) as $fields |
  if ($fields | length) != 5 then fail("cron must contain five fields") else . end |
  ({jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12}) as $months |
  ({sun:0,mon:1,tue:2,wed:3,thu:4,fri:5,sat:6}) as $weekdays |
  (cron_field($fields[0]; 0; 59; null)) as $minutes |
  (cron_field($fields[1]; 0; 23; null)) as $hours |
  (cron_field($fields[2]; 1; 31; null)) as $days |
  (cron_field($fields[3]; 1; 12; $months)) as $month_field |
  (cron_field($fields[4]; 0; 6; $weekdays)) as $weekday_field |
  ($since | localtime | pseudo_time(.)) as $local_since |
  ($now | localtime | pseudo_time(.)) as $local_now |
  ($since | localtime | [.[0], .[1], .[2], 0, 0, 0, 0, 0] | mktime) as $first_day |
  ($now | localtime | [.[0], .[1], .[2], 0, 0, 0, 0, 0] | mktime) as $last_day |
  if $local_now <= $local_since then
    {due:false, normalized:$normalized}
  elif (($last_day - $first_day) / 86400) > 1832 then
    {due:true, normalized:$normalized}
  else
    ([range($first_day; $last_day + 86400; 86400) as $day |
      ($day | gmtime) as $date |
      select(contains_value($month_field; $date[1] + 1)) |
      (contains_value($days; $date[2])) as $day_matches |
      (contains_value($weekday_field; $date[6])) as $weekday_matches |
      select(if $days.star or $weekday_field.star
             then $day_matches and $weekday_matches
             else $day_matches or $weekday_matches end) |
      $hours.values[] as $hour |
      $minutes.values[] as $minute |
      ($day + $hour * 3600 + $minute * 60) as $candidate |
      select($candidate > $local_since and $candidate <= $local_now)] | length > 0) as $due |
    {due:$due, normalized:$normalized}
  end
end
