// Поставка вендора основної конфігурації на підтримці (еталон — tools/lib/Supply.psm1): ЄДИНЕ оголошення шляху
// поставки, її стан на цій машині й текст відновлення. У теці `Ext/ParentConfigurations` лежить `<Ім'я>.cf`
// поставки (поза git: сотні МБ) і позначка `.kit-bin-sha1` (стан машини); `Ext/ParentConfigurations.bin` —
// ознаки підтримки (замки об'єктів) — лишається в git. Модуль бібліотечний, без друку; нічого не змінює на диску
// (запис позначки й видалення теки — команди `sync`/`verify`/`adopt`, їхні копії лишаються в PowerShell).
//
// Відмінність від PowerShell (ADR-0021 п. 2): збій читання поставки — стан `Unknown` (текст рецепта `unknown`
// у PowerShell уже був), а не виняток і не «немає».
//
// SHA-1 .bin — власна реалізація (нових залежностей немає без рішення архітектора); криптографічної стійкості
// від неї не вимагається: позначка лише виявляє зміну файла, а не захищає від зловмисника.

use crate::case_guard::fold;
use std::fs;
use std::io;
use std::path::Path;

/// Шлях теки поставки відносно кореня дерева CONFIGURATION.
pub const RELATIVE_PATH: &str = "Ext/ParentConfigurations";
/// Ознаки підтримки: описують поставку (файл більший за `EMPTY_BIN_BYTES`).
pub const BIN_RELATIVE_PATH: &str = "Ext/ParentConfigurations.bin";
pub const MARKER_NAME: &str = ".kit-bin-sha1";
/// У знятих з підтримки конфігураціях `.bin` рівно 16 байт — `{6,0,0,0,1,0}` з BOM.
pub const EMPTY_BIN_BYTES: u64 = 16;

/// Чи шлях (відносно дерева джерела) належить теці поставки — без регістру, як NTFS.
pub fn is_supply_relative_path(relative: &str) -> bool {
    let rel = fold(relative.replace('\\', "/").trim_start_matches('/'));
    let supply = fold(RELATIVE_PATH);
    rel == supply
        || rel
            .strip_prefix(&supply)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// Стан поставки.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    /// `.bin` поставки не описує: правило не діє.
    None,
    /// Позначка = SHA-1 поточного `.bin`.
    Current,
    /// Позначка ≠ SHA-1 (хибна тривога можлива й прийнята: перевідновити дешевше, ніж пропустити пару
    /// «новий .bin + старий .cf»).
    Stale,
    /// `.bin` описує поставку, а `.cf` чи позначки немає.
    Missing,
    /// Поставку не вдалося прочитати; текст — причина (помилка ОС).
    Unknown(String),
}

/// Чи описує `.bin` поставку: файл більший за 16 байт. Немає файла — `false`; інша помилка читання — `Err`.
pub fn is_described(tree_root: &Path) -> io::Result<bool> {
    match fs::metadata(tree_root.join(BIN_RELATIVE_PATH)) {
        Ok(m) => Ok(m.is_file() && m.len() > EMPTY_BIN_BYTES),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// SHA-1 `.bin` — малі шістнадцяткові цифри.
pub fn bin_sha1(tree_root: &Path) -> io::Result<String> {
    Ok(sha1_hex(&fs::read(tree_root.join(BIN_RELATIVE_PATH))?))
}

/// Стан поставки на цій машині (`Get-KitSupplyState`).
pub fn state(tree_root: &Path) -> State {
    match state_io(tree_root) {
        Ok(s) => s,
        Err(e) => State::Unknown(e.to_string()),
    }
}

fn state_io(tree_root: &Path) -> io::Result<State> {
    if !is_described(tree_root)? {
        return Ok(State::None);
    }
    let dir = tree_root.join(RELATIVE_PATH);
    let has_cf = match fs::read_dir(&dir) {
        Ok(entries) => {
            let mut found = false;
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().to_lowercase();
                if name.ends_with(".cf") && entry.file_type()?.is_file() {
                    found = true;
                }
            }
            found
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => false,
        Err(e) => return Err(e),
    };
    let marker = dir.join(MARKER_NAME);
    let recorded = match fs::metadata(&marker) {
        Ok(m) if m.is_file() => Some(fs::read(&marker)?),
        Ok(_) => None,
        Err(e) if e.kind() == io::ErrorKind::NotFound => None,
        Err(e) => return Err(e),
    };
    let (true, Some(recorded)) = (has_cf, recorded) else {
        return Ok(State::Missing);
    };
    let recorded = String::from_utf8_lossy(&recorded).trim().to_string();
    if recorded.eq_ignore_ascii_case(&bin_sha1(tree_root)?) {
        Ok(State::Current)
    } else {
        Ok(State::Stale)
    }
}

/// Стан, для якого існує рецепт відновлення.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecipeState {
    Stale,
    Missing,
    Unknown,
}

/// Для чого рецепт: `check` лише попереджає й веде до `kit verify`; `stop` — зупинка після sync/verify, де база
/// агента вже має версію сховища (видалення теки поставки, повний pull Уніки, позначка).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Check,
    Stop,
}

/// Єдине джерело тексту відновлення поставки (`Get-KitSupplyRecipe`). `on_main_branch` — поточна гілка головна:
/// поставку відновлюють лише на головній, на гілці задачі рецепт каже «спершу поставка на головній гілці».
pub fn recipe(
    source_key: &str,
    workspace: &str,
    main_branch: &str,
    state: RecipeState,
    purpose: Purpose,
    on_main_branch: bool,
) -> String {
    let what = match state {
        RecipeState::Stale => {
            "поставка вендора застаріла: позначка .kit-bin-sha1 не збігається з поточним Ext/ParentConfigurations.bin (оновився реліз вендора або об'єкти переведено в редаговані — друге дає зайве, але безпечне відновлення)"
        }
        RecipeState::Unknown => {
            "стан поставки вендора не обчислено: помилка читання Ext/ParentConfigurations — невідоме трактується як відсутнє"
        }
        RecipeState::Missing => {
            "поставка вендора відсутня: Ext/ParentConfigurations.bin описує поставку, а .cf чи позначки .kit-bin-sha1 на цій машині немає — повне завантаження в базу впаде"
        }
    };
    let head = format!("{what}. Відновлення поставки вендора: ");
    let onboarding = format!(
        " У рецепті (i) (новий репозиторій, онбординг на гілці через sync -MergeInto) той самий крок друкує kit sync -Source {source_key}."
    );
    if !on_main_branch {
        return format!(
            "{head}спершу поставка на головній гілці {main_branch}, а не на гілці задачі (HEAD = {main_branch}, дерево чисте): перейдіть на {main_branch} і виконайте там kit verify -Source {source_key}, далі — надруковане ним; потім поверніться на гілку задачі.{onboarding}"
        );
    }
    if purpose == Purpose::Check {
        return format!(
            "{head}на гілці {main_branch} (HEAD = {main_branch}, дерево чисте), база агента є (інакше v8storagekit:infobase-agent): kit verify -Source {source_key} (очікувано equal; verify наповнить базу версією зі сховища — merge-base) → виконати його зупинку поставки.{onboarding}"
        );
    }
    let key_json = serde_json::to_string(source_key).unwrap_or_default();
    let pull = format!(
        "unica.run {{\"op\":\"pull\",\"args\":{{\"sourceSet\":{key_json},\"force\":true}},\"dryRun\":true}}"
    );
    format!(
        "{head}на гілці {main_branch} (HEAD = {main_branch}, дерево чисте) спершу видаліть теку <шлях набору {source_key}>/Ext/ParentConfigurations/ цілою (вона вся поза git; kit нічого не видаляє — видаляє людина чи агент), далі повний pull цього набору: {pull} (спершу так, потім той самий виклик з \"dryRun\":false; Уніка спитає людину про перезапис бази origin — це очікувано) → kit supply-marker -Workspace {workspace} -Source {source_key} -Apply. Після повного pull база, дерево й пам'ять Уніки узгоджені — push force не потрібен. Після pull git status --porcelain -- <шлях набору {source_key}> мусить бути порожнім; непорожній — зупинка й доповідь людині. Без обходу."
    )
}

/// SHA-1 (FIPS 180-4) — шістнадцяткові малі цифри.
fn sha1_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let mut msg = data.to_vec();
    let bit_len = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in msg.as_chunks::<64>().0 {
        let mut w = [0u32; 80];
        for (i, word) in chunk.as_chunks::<4>().0.iter().enumerate() {
            w[i] = u32::from_be_bytes(*word);
        }
        for i in 16..80 {
            w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotate_left(1);
        }
        let [mut a, mut b, mut c, mut d, mut e] = h;
        for (i, wi) in w.iter().enumerate() {
            let (f, k) = match i {
                0..=19 => ((b & c) | (!b & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let t = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*wi);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = t;
        }
        for (slot, v) in h.iter_mut().zip([a, b, c, d, e]) {
            *slot = slot.wrapping_add(v);
        }
    }
    h.iter().map(|v| format!("{v:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::sha1_hex;

    // Контроль власної реалізації: відомі вектори FIPS 180 (порожній, «abc», дві ітерації блока, мільйон «a» не
    // потрібен) і межа добивки (55/56/64 байти).
    #[test]
    fn sha1_matches_known_vectors() {
        assert_eq!(sha1_hex(b""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
        assert_eq!(sha1_hex(b"abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
        assert_eq!(
            sha1_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        );
        assert_eq!(
            sha1_hex(&[b'a'; 64]),
            "0098ba824b5c16427bd7a1122a5a442a25ec644d"
        );
    }
}
