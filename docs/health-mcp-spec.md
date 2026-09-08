# Health MCP — Design Spec

**Status:** Draft v1.2 · **Date:** 2026-09-07

## 1. Overview

Agents need health data to give useful advice, and Apple Health holds most of it but has no agent-facing API. Health MCP is a small system that exports a user's Apple Health data, end-to-end encrypted, to cloud storage and exposes it to any agent through a standard OAuth-protected MCP server.

Three components:

| Component | Runs on | Responsibility |
|---|---|---|
| **iOS app** | User's iPhone | Reads HealthKit, encrypts, uploads chunks; approves agent pairings |
| **Worker** | Cloudflare Workers + D1 + R2 | Accepts uploads, maintains plaintext catalog, serves the MCP + OAuth endpoints |
| **Agent** | Anywhere with a code sandbox | Authenticates via OAuth, fetches encrypted chunks, decrypts locally with the user key |

Guiding principle: **Apple Health is the source of truth; everything in the cloud is a re-creatable encrypted cache.** This makes account loss, key rotation, and schema migration cheap (re-dump from device) and drives several of the simplifications below.

## 2. Goals and non-goals

**Goals**
- Full e2e encryption: the Worker never sees plaintext health values or the user key.
- Agent ergonomics: discover available series and date ranges, pull focused slices ("steps for these two weeks"), know how fresh the data is.
- Decryption implementable in ~5 lines in Node, Python, Go, Rust, WebCrypto with at most one dependency.
- Minimal auth overhead: no passwords, no SMS, no identity provider to operate.
- Both health series (HR, HRV, glucose, sleep, …) and fitness data (workouts incl. routes).

**Non-goals (v1)**
- Agents without a code sandbox (a chat-only client cannot decrypt).
- Hosted / server-side decryption, now or later. The service never touches unencrypted health data.
- Multi-device accounts or account recovery. Re-onboarding is the recovery path.
- Write access to HealthKit.
- Pure-bash decryption. `openssl enc` cannot do AES-GCM; shell-only agents use the Python/Node reference script.

## 3. Threat model

| Threat | Mitigation |
|---|---|
| R2 bucket / D1 leak | Values are AES-256-GCM encrypted under an 80-bit random key never stored server-side; catalog is coarse (see §7) |
| Compromised Worker | Same — Worker holds ciphertext, catalog, and OAuth tokens only |
| Blob swapping between users/series/days | Object path bound as GCM AAD |
| Key typo by user | Check character on the key; local known-plaintext check blob |
| Stolen OAuth token | Grants access to ciphertext only; useless without the key |
| Lost phone | Data is a cache; user re-onboards with a new key and re-dumps |

**Accepted exposure:** the plaintext catalog reveals *which* series a user tracks and on which days chunks exist (see §7 for what is deliberately kept out of it).

## 4. User key and cryptography

### 4.1 User key
- Generated on device at onboarding, stored in Keychain, never transmitted.
- Format: 16 characters from Crockford base32 (`0-9 A-H J K M N P-T V-Z`, no I/L/O/U), displayed as `XXXX-XXXX-XXXX-XXXX`, plus a 17th check character. 80 bits of entropy.
- Normalization before use: uppercase, strip dashes and whitespace, validate check char.
- Shown to the user as text and QR; the user pastes it into the agent's configuration.
- Rotation: generate a new key on device, re-encrypt/re-upload all chunks, delete old objects.

### 4.2 Key derivation
The key is random, so no stretching is needed:

```
K = SHA-256("healthmcp/v1:" + normalized_key)      // 32-byte AES key
```

### 4.3 Cipher
- AES-256-GCM, 12-byte random nonce per object, 16-byte tag.
- AAD = the object's R2 path (e.g. `u_abc/heart_rate/2026-09-07`), so a blob only decrypts at the path it was written to.
- Plaintext is gzip-compressed JSON before encryption.

Rationale: GCM is built into Node `crypto`, Go, Rust, and WebCrypto; Python needs one package (`cryptography`) since the stdlib has no AES under any scheme. Pure bash is explicitly **not a target**: `openssl enc` rejects AEAD modes, and supporting it would mean either a weaker single scheme (CBC+HMAC, where shell agents tend to skip MAC verification) or dual-uploading every chunk. Shell-only agents run the Python/Node reference script.

### 4.4 Envelope format
Every object is a small JSON document:

```json
{
  "v": 1,
  "alg": "A256GCM",
  "kdf": "sha256",
  "iv": "<base64, 12 bytes>",
  "ct": "<base64, ciphertext || 16-byte tag>"
}
```

### 4.5 Key check
Each user namespace contains `check.enc`, an envelope encrypting the literal `ok` with AAD `<user>/check`. Agents verify a pasted key locally before fetching data, without the key ever leaving the sandbox.

### 4.6 Reference decryption (Python)

```python
import base64, gzip, hashlib, json
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def decrypt(envelope: dict, user_key: str, path: str) -> object:
    k = hashlib.sha256(b"healthmcp/v1:" + user_key.upper().replace("-", "").encode()).digest()
    iv, ct = base64.b64decode(envelope["iv"]), base64.b64decode(envelope["ct"])
    return json.loads(gzip.decompress(AESGCM(k).decrypt(iv, ct, path.encode())))
```

Equivalent Node snippet uses `crypto.createDecipheriv("aes-256-gcm", …)` with `setAAD` / `setAuthTag`.

## 5. Data model

### 5.1 Series
A **series** is one HealthKit type mapped to a stable snake_case id: `heart_rate`, `hrv_sdnn`, `resting_heart_rate`, `steps`, `blood_glucose`, `sleep`, `active_energy`, `body_mass`, `workouts`, `daily_summary`, … The app ships a whitelist; new types are added deliberately.

### 5.2 Chunking

| Series class | Chunk | Examples |
|---|---|---|
| High-frequency samples | one object per series per day | HR, HRV, steps, glucose, sleep |
| Sparse samples | one object per series per month | body mass, blood pressure |
| Workouts | one object per workout, keyed by HealthKit UUID; includes route/GPS and in-workout HR | `workouts` |
| Records | one object per record | `ecg` |
| Profile | one object per user | `profile` |
| Summaries | one object per month | `daily_summary` |

Sample records inside a chunk (units are fixed per series by Appendix A, not repeated per sample):

```json
{"t":  "2026-09-07T06:12:00Z", "v": 62, "src": "Apple Watch"}                        // instantaneous
{"t0": "2026-09-07T06:00:00Z", "t1": "2026-09-07T07:00:00Z", "v": 812, "src": "iPhone"}  // interval/cumulative
{"t0": "2026-09-06T23:10:00Z", "t1": "2026-09-07T00:40:00Z", "c": "asleepDeep"}        // category
```

`src` is kept because iPhone and Watch both write overlapping samples for cumulative types; raw chunks are not deduplicated, `daily_summary` is (computed with `HKStatisticsQuery`, which merges sources). Sleep samples are assigned to the day of `t1` so a night stays in one chunk. Workout and ECG object shapes are in Appendix A.

### 5.3 Daily summary
Computed **on device** (the only place plaintext exists): resting HR, HRV avg, steps total, sleep totals, active energy, workout count. One monthly object gives an agent a cheap overview before pulling raw samples.

## 6. Storage layout (R2)

```
{user_id}/check.enc
{user_id}/{series}/{YYYY-MM-DD}.enc        # daily chunks
{user_id}/{series}/{YYYY-MM}.enc           # monthly chunks
{user_id}/workouts/{YYYY-MM-DD}/{hk_uuid}.enc   # one per workout
{user_id}/ecg/{YYYY-MM-DD}/{hk_uuid}.enc        # one per ECG record
{user_id}/profile.enc
```

Object names reveal series id and date to the server; values do not. HealthKit UUIDs are random and leak nothing. Chunk objects are overwritten in place on re-sync; workout and ECG objects are immutable once written (write-once, deleted when HealthKit reports the deletion).

## 7. Catalog (D1)

Plaintext, deliberately coarse. It exists for `list_series`, chunk resolution in `get_samples`, and operational visibility (debugging sync, expiry, storage accounting).

```sql
CREATE TABLE users (
  id            TEXT PRIMARY KEY,      -- app-generated UUID
  device_pubkey TEXT NOT NULL,         -- Secure Enclave public key (uploads)
  apns_token    TEXT,                  -- for request_sync
  created_at    INTEGER NOT NULL
);

CREATE TABLE series (
  user_id        TEXT NOT NULL,
  series         TEXT NOT NULL,
  first_day      TEXT NOT NULL,        -- YYYY-MM-DD
  last_day       TEXT NOT NULL,
  total_samples  INTEGER NOT NULL,
  last_synced_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, series)
);

CREATE TABLE chunks (
  user_id    TEXT NOT NULL,
  series     TEXT NOT NULL,
  period     TEXT NOT NULL,            -- YYYY-MM-DD or YYYY-MM
  object_key TEXT NOT NULL,
  bytes      INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, object_key)
);
CREATE INDEX chunks_lookup ON chunks (user_id, series, period);
```

**Deliberately not in the catalog** (each would leak values by inference):
- per-day sample counts (glucose readings/day ≈ CGM vs. finger-stick; zero HR samples ≈ watch off)
- timestamps on workout rows. One row per workout exists (keyed by opaque HealthKit UUID and day), so workout count per day and approximate object size are visible; start/end/duration are not
- units, aggregates, or anything derived from values — those live inside encrypted chunks

Future hardening, drop-in if needed: replace `series` with `HMAC(K, series)` so the server sees opaque ids and the agent maps them locally. Touches only the catalog and `list_series`.

## 8. Sync (iOS app)

There is no fixed interval; iOS does not allow one. Sync is trigger-driven:

1. **HealthKit background delivery** (`HKObserverQuery` + `enableBackgroundDelivery`) per type. Frequency caps: `.immediate` for HR/HRV/glucose/workouts, `.hourly` for cumulative types (steps, distance), `.daily` for sleep. Primary path; yields ~hourly freshness.
2. **Foreground sync** on every app open.
3. **Nightly `BGProcessingTask`** as a backstop: reconcile anchors, re-upload anything missed.
4. **Push-requested sync** (§10).

Mechanics:
- `HKAnchoredObjectQuery` per type for deltas; the app tracks affected periods and rewrites only those chunks.
- Debounce: coalesce triggers and upload after ~10 minutes of quiet.
- Uploads are signed with the device key (`PUT /v1/upload` with `series`, `period`, envelope body). The Worker writes R2, upserts `chunks` and `series`, and bumps `last_synced_at`.
- Known limitation: a force-quit app receives no background delivery until reopened. `last_synced_at` makes this visible to agents.

## 9. Auth

Two independent auth paths; neither involves a password, SMS, or external IdP.

### 9.1 App → Worker
Device-bound identity. On first launch the app generates a Secure Enclave keypair, calls `POST /v1/register` with the public key, and receives a `user_id`. All app requests are signed. No login screen. (Sign in with Apple can be layered on later if multi-device accounts are ever wanted.)

### 9.2 Agent → Worker (MCP OAuth)
- Built on `workers-oauth-provider`: dynamic client registration, PKCE, token issuance/storage in KV or D1.
- Custom authorize handler = **pairing code**, not a web login:
  1. Agent client opens `/authorize`; page shows a 6-digit code (also as QR / universal link).
  2. User enters the code in the iOS app (or scans / taps). App signs the approval with the device key and posts it to the Worker.
  3. Worker binds the OAuth session to `user_id` and completes the code → token exchange.
- Access tokens grant ciphertext access only. Refresh tokens long-lived; user can revoke agents from the app.

The user key is never an auth credential and never reaches the server.

## 10. MCP server

### 10.1 Initialization
The `initialize` response's `instructions` field contains the decryption recipe (§4), the key-check procedure, and a note that ciphertext must be fetched and decrypted in a sandbox, not read into the model's context.

### 10.2 Tools

**`list_series()`**
Returns, per series: id, unit (from the static mapping in Appendix A), `first_day`, `last_day`, `total_samples`, `last_synced_at`. Also returns `check_url` for `check.enc`.

**`get_samples(series, start, end)`**
Resolves covering chunks from the catalog and returns a manifest:
```json
{
  "series": "steps",
  "chunks": [
    {"period": "2026-09-01", "path": "u_abc/steps/2026-09-01", "url": "https://…", "bytes": 4120},
    …
  ],
  "expires_at": "…",
  "last_synced_at": "…",
  "decrypt": "see instructions; AAD is the 'path' field"
}
```
URLs are Worker-signed, ~10-minute TTL. The agent's sandbox fetches, decrypts, and filters to the exact range client-side.

**`get_workouts(start, end)`**
Same shape; one manifest entry per workout, resolved from catalog rows by day.

**`get_profile()`**
Manifest for `profile.enc` (characteristics: DOB, sex, blood type, …).

**`get_daily_summary(start, end)`**
Same shape over `daily_summary` (monthly chunks).

**`request_sync()`**
Best-effort freshness request (§11). Returns `{"requested_at", "last_synced_at", "advice": "poll list_series in ~60s"}`.

### 10.3 Resources
- `health://decrypt/python`, `health://decrypt/node` — working reference scripts.

### 10.4 Design rule
**Ciphertext never flows through the LLM context.** Tools return manifests and URLs; bytes go straight to the sandbox.

## 11. Request sync (push)

Silent APNs pushes are cheap to build but unreliable by design (battery heuristics, Low Power Mode drops them, force-quit apps never receive them, no delivery feedback). The cases that most need a push are the ones where it is least likely to work, so it only pays off with a visible fallback:

1. `request_sync` sends a background push (`content-available: 1`, `apns-push-type: background`, priority 5).
2. If no upload lands within ~2 minutes, send a visible notification: "Your assistant wants fresh health data — tap to sync." Tapping opens the app → foreground sync, which is guaranteed.
3. Rate-limit per user (e.g. one visible notification per 15 minutes).

## 12. Onboarding flow

1. Install app → device key generated → `/v1/register` → `user_id`.
2. HealthKit permission prompt (whitelisted types).
3. User key generated and shown (text + QR) with "save this; we cannot recover it."
4. Initial full export (may take minutes; runs in foreground with progress).
5. "Connect an agent": add the MCP URL to the agent, complete the pairing code flow, paste the user key into the agent.

## 13. Worker API summary

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /v1/register` | none (returns user_id) | Register device public key |
| `PUT /v1/upload` | device signature | Upload one chunk |
| `POST /v1/pair/approve` | device signature | Approve a pairing code |
| `POST /v1/apns` | device signature | Register push token |
| `/authorize`, `/token`, `/register` | OAuth | `workers-oauth-provider` endpoints |
| `/mcp` | OAuth bearer | MCP transport |
| `GET /v1/blob/{signed}` | signed URL | Chunk download |

## 14. Decisions on previously open items

| Item | Decision |
|---|---|
| Retention | Keep everything (raw chunks, workouts, ECG, summaries) indefinitely. Revisit only if storage cost becomes material. |
| Hosted / non-e2e decrypt tier | **No.** The service never handles unencrypted health data, even transiently. Sandbox-less agents are unsupported. |
| Series-id hashing (§7) | Not for v1. Catalog keeps plaintext series ids. |
| Multi-device / Sign in with Apple | Out of scope. Device-bound identity only. |

## 15. Remaining open items

- ECG and route payload sizes: confirm gzipped sizes on real data before leaving both on by default.

---

## Appendix A — HealthKit type whitelist and mapping

Tiers: **default** = enabled at onboarding once HealthKit permission is granted; **opt-in** = off by default, toggled per group in the app. Chunk = `day` or `month` (§5.2). Background delivery frequency follows Apple's per-type minimums: `.immediate` where allowed, `.hourly` for cumulative types, `.daily` for sleep.

### A.1 Instantaneous quantity series — record shape `{t, v, src}`

| series id | HKQuantityTypeIdentifier | unit | chunk | tier |
|---|---|---|---|---|
| `heart_rate` | HeartRate | count/min | day | default |
| `resting_heart_rate` | RestingHeartRate | count/min | month | default |
| `walking_hr_avg` | WalkingHeartRateAverage | count/min | month | default |
| `hr_recovery_1min` | HeartRateRecoveryOneMinute | count/min | month | default |
| `hrv_sdnn` | HeartRateVariabilitySDNN | ms | day | default |
| `blood_oxygen` | OxygenSaturation | % | day | default |
| `respiratory_rate` | RespiratoryRate | count/min | day | default |
| `body_temperature` | BodyTemperature | °C | month | default |
| `wrist_temperature` | AppleSleepingWristTemperature | °C | month | default |
| `blood_pressure_systolic` | BloodPressureSystolic | mmHg | month | default |
| `blood_pressure_diastolic` | BloodPressureDiastolic | mmHg | month | default |
| `blood_glucose` | BloodGlucose | mg/dL | day | default |
| `vo2_max` | VO2Max | mL/kg/min | month | default |
| `body_mass` | BodyMass | kg | month | default |
| `body_fat` | BodyFatPercentage | % | month | default |
| `lean_body_mass` | LeanBodyMass | kg | month | default |
| `bmi` | BodyMassIndex | count | month | default |
| `height` | Height | m | month | default |
| `waist_circumference` | WaistCircumference | m | month | default |
| `walking_speed` | WalkingSpeed | m/s | month | default |
| `walking_step_length` | WalkingStepLength | m | month | default |
| `walking_asymmetry` | WalkingAsymmetryPercentage | % | month | default |
| `walking_double_support` | WalkingDoubleSupportPercentage | % | month | default |
| `stair_ascent_speed` | StairAscentSpeed | m/s | month | default |
| `stair_descent_speed` | StairDescentSpeed | m/s | month | default |
| `six_minute_walk` | SixMinuteWalkTestDistance | m | month | default |
| `running_power` | RunningPower | W | day | default |
| `running_speed` | RunningSpeed | m/s | day | default |
| `running_stride_length` | RunningStrideLength | m | day | default |
| `running_vertical_oscillation` | RunningVerticalOscillation | cm | day | default |
| `running_ground_contact` | RunningGroundContactTime | ms | day | default |
| `cycling_power` | CyclingPower | W | day | default |
| `cycling_cadence` | CyclingCadence | rpm | day | default |
| `cycling_speed` | CyclingSpeed | m/s | day | default |
| `cycling_ftp` | CyclingFunctionalThresholdPower | W | month | default |
| `basal_body_temperature` | BasalBodyTemperature | °C | month | opt-in (reproductive) |
| `environmental_audio` | EnvironmentalAudioExposure | dBASPL | day | opt-in (audio) |
| `headphone_audio` | HeadphoneAudioExposure | dBASPL | day | opt-in (audio) |

Blood pressure is read via `HKCorrelationTypeIdentifierBloodPressure` and split into the two series above with a shared `t`.

### A.2 Cumulative / interval quantity series — record shape `{t0, t1, v, src}`

| series id | HKQuantityTypeIdentifier | unit | chunk | tier |
|---|---|---|---|---|
| `steps` | StepCount | count | day | default |
| `distance_walking_running` | DistanceWalkingRunning | m | day | default |
| `distance_cycling` | DistanceCycling | m | day | default |
| `distance_swimming` | DistanceSwimming | m | day | default |
| `flights_climbed` | FlightsClimbed | count | day | default |
| `active_energy` | ActiveEnergyBurned | kcal | day | default |
| `basal_energy` | BasalEnergyBurned | kcal | day | default |
| `exercise_minutes` | AppleExerciseTime | min | day | default |
| `stand_minutes` | AppleStandTime | min | day | default |
| `time_in_daylight` | TimeInDaylight | min | day | default |
| `physical_effort` | PhysicalEffort | kcal/hr/kg | day | default |
| `dietary_energy` | DietaryEnergyConsumed | kcal | day | opt-in (nutrition) |
| `dietary_carbs` | DietaryCarbohydrates | g | day | opt-in (nutrition) |
| `dietary_protein` | DietaryProtein | g | day | opt-in (nutrition) |
| `dietary_fat` | DietaryFatTotal | g | day | opt-in (nutrition) |
| `dietary_water` | DietaryWater | mL | day | opt-in (nutrition) |
| `dietary_caffeine` | DietaryCaffeine | mg | day | opt-in (nutrition) |

### A.3 Category series — record shape `{t0, t1, c, meta?}`

| series id | HKCategoryTypeIdentifier | `c` values | chunk | tier |
|---|---|---|---|---|
| `sleep` | SleepAnalysis | `inBed`, `asleepUnspecified`, `asleepCore`, `asleepDeep`, `asleepREM`, `awake` | day (by `t1`) | default |
| `stand_hour` | AppleStandHour | `stood`, `idle` | day | default |
| `mindful_session` | MindfulSession | — | month | default |
| `heart_rate_events` | HighHeartRateEvent, LowHeartRateEvent, IrregularHeartRhythmEvent | `high`, `low`, `irregular` (+ `meta.threshold`) | month | default |
| `low_cardio_fitness_event` | LowCardioFitnessEvent | — (+ `meta.vo2_max`) | month | default |
| `menstrual_flow` | MenstrualFlow | `unspecified`, `light`, `medium`, `heavy`, `none` | month | opt-in (reproductive) |
| `reproductive_events` | OvulationTestResult, CervicalMucusQuality, IntermenstrualBleeding, PregnancyTestResult, ProgesteroneTestResult, Contraceptive, Lactation, Pregnancy, InfrequentMenstrualCycles, IrregularMenstrualCycles, ProlongedMenstrualPeriods, PersistentIntermenstrualBleeding | `c` = type id, `meta.value` = HK enum name | month | opt-in (reproductive) |
| `symptoms` | all ~40 `HKCategoryTypeIdentifier` symptom types (AbdominalCramps, Fatigue, Headache, Nausea, …) | `c` = symptom id, `meta.severity` ∈ `present`, `notPresent`, `mild`, `moderate`, `severe` | month | opt-in (symptoms) |

### A.4 Workouts — one object per workout

Source: `HKWorkout` (+ `HKWorkoutActivity` for multisport), `HKWorkoutRoute` via `HKWorkoutRouteQuery`, and in-workout `heart_rate` samples selected by workout predicate. Statistics come from `HKWorkout.statistics(for:)`.

```json
{
  "id": "<hk_uuid>",
  "type": "running",                        // HKWorkoutActivityType name, snake_case
  "t0": "2026-09-07T06:00:12Z", "t1": "2026-09-07T06:48:40Z",
  "duration_s": 2908,
  "src": "Apple Watch",
  "stats": {"active_energy_kcal": 512, "distance_m": 8120, "avg_hr": 151, "max_hr": 174,
            "elevation_gain_m": 84, "avg_pace_s_per_km": 358},
  "activities": [ {"type": "running", "t0": "…", "t1": "…"} ],   // multisport segments, else one entry
  "heart_rate": [ {"t": "…", "v": 138}, … ],
  "route": [ {"t": "…", "lat": 37.79, "lon": -122.40, "alt_m": 12.1, "h_acc_m": 5}, … ],
  "meta": { "indoor": false, "weather_temp_c": 14 }
}
```

Only workouts with `t1` set (ended) are exported. Deletions are propagated via anchored query `deletedObjects` → delete the R2 object and catalog row.

### A.5 Records and per-user objects

| series id | source | shape / notes | chunk | tier |
|---|---|---|---|---|
| `ecg` | HKElectrocardiogram + `HKElectrocardiogramQuery` voltages | `{id, t, classification, avg_hr, sampling_hz, voltage_uv: [...]}` (~15k samples per record) | one per record | default |
| `activity_rings` | HKActivitySummary | per day: `{d, move_kcal, move_goal, exercise_min, exercise_goal, stand_h, stand_goal}` | month | default |
| `daily_summary` | computed on device with HKStatisticsQuery | per day: `{d, resting_hr, hrv_avg, steps, active_energy, exercise_min, sleep_total_min, sleep_by_stage, workouts, glucose_avg?, blood_oxygen_avg?}` | month | default |
| `profile` | HKCharacteristicType: DateOfBirth, BiologicalSex, BloodType, FitzpatrickSkinType, WheelchairUse, ActivityMoveMode | single object | one per user | default |

### A.6 Excluded from v1

- Clinical health records (`HKClinicalType`, FHIR) — separate entitlement and review process; different product surface.
- Audiograms, vision prescriptions, UV exposure, toothbrushing, handwashing, `AppleMoveTime`, insulin delivery, inhaler usage, and other niche or deprecated types.
- Anything not listed above is not read, even if the user grants broad permission; adding a type is a deliberate spec change.
