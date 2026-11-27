// Локальні файли й воркспейс: `overlay-connection` (накладка), `build-artifacts` і `local-audit` (воркспейс).
// `local-ignored` — страж, див. `guards`.

use super::Collector;
use super::gitq::slashed;
use crate::config::agent_base::{Canonical, CollisionKind, canonical_form, dev_base_overlaps};
use crate::config::connection::{CredentialsKind, credentials_recipe};
use crate::config::manifest::Manifest;
use crate::config::v8project::read_local_infobase;
use crate::config::{Context, Level, RawConnection, Workspace};
use std::path::Path;

/// Підключення кожної дев-бази накладки розбирається й тоді, коли її ні з чим не звіряють: нерозбірне
/// підключення (непарна лапка, голий шлях, `Srvr=` без `Ref=`) інакше проходило б `check` і падало лише на `dump`.
/// Та сама канонізація, що у перетинах баз (ADR-0021 п. 7): відносний `File=` дає warn тут. warn, не error: error
/// гасив би сигнали сховищ у хуку старту сесії, а дев-база потрібна лише `dump`. Накладка є, але не розібрана
/// — «не перевірено».
pub(super) fn overlay_connection(c: &mut Collector, ctx: &Context) {
    let Some(overlay_path) = ctx.overlay_path.as_deref() else {
        return;
    };
    let Some(overlay) = &ctx.overlay else {
        return c.unchecked(
            "overlay-connection",
            "підключення дев-баз накладки",
            "накладку не розібрано",
        );
    };
    for human in &overlay.infobases {
        if let Canonical::Unparsed {
            reason,
            credentials,
        } = canonical_form(human.connection.expose())
        {
            let recipe = credentials
                .as_ref()
                .map(|e| credentials_recipe(e, CredentialsKind::Overlay))
                .unwrap_or_default();
            let tail = if recipe.is_empty() {
                String::new()
            } else {
                format!(" {recipe}")
            };
            c.add(
                Level::Warn,
                "overlay-connection",
                format!("Дев-база '{}' у {overlay_path}: {reason}{tail}", human.name),
            );
        }
    }
}

const ARTIFACT_EXTENSIONS: [&str; 4] = [".epf", ".erf", ".cfe", ".cf"];

/// Розширення за правилом `Path.GetExtension`: від останньої крапки імені файла; порожнє, коли крапка остання.
fn extension(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(i) if i.saturating_add(1) < name.len() => {
            name.get(i..).unwrap_or_default().to_lowercase()
        }
        _ => String::new(),
    }
}

/// Артефакти збірки в git не лежать: бінарний блоб лишається в історії назавжди. Єдине їх місце — під
/// `<воркспейс>/<workPath>/` (гітігнорована; приймається весь префікс). Рівень warn: у формі 0.6.0 артефакти в git
/// були законною нормою, і error завалив би перехід. `.erf` понад три розширення свідомо: зовнішній звіт збирає
/// та сама команда платформи, що й `.epf`.
pub(super) fn build_artifacts(c: &mut Collector, ctx: &Context, ws: &Workspace) {
    let root = Path::new(&ctx.repo_root);
    let work_path = if ws.project.work_path.is_empty() {
        "build"
    } else {
        ws.project.work_path.as_str()
    };
    let ws_prefix = slashed(&ws.path);
    let work_prefix = format!("{ws_prefix}/{}/", slashed(work_path));
    let files = match c.tracked(root, &ws.path) {
        Ok(f) => f,
        Err(reason) => {
            return c.unchecked(
                "build-artifacts",
                &format!("{}: артефакти збірки в git", ws.path),
                &reason,
            );
        }
    };
    let lower_prefix = work_prefix.to_lowercase();
    let committed: Vec<&String> = files
        .iter()
        .filter(|f| ARTIFACT_EXTENSIONS.contains(&extension(f).as_str()))
        .filter(|f| !f.to_lowercase().starts_with(&lower_prefix))
        .collect();
    if committed.is_empty() {
        return;
    }
    let shown: Vec<&str> = committed.iter().take(5).map(|s| s.as_str()).collect();
    let tail = if committed.len() > 5 {
        format!(" та ще {}", committed.len().saturating_sub(5))
    } else {
        String::new()
    };
    c.add(
        Level::Warn,
        "build-artifacts",
        format!(
            "{}: у git лежать артефакти збірки — {} файл(ів): {}{tail}. Вони похідні, і закомічений артефакт застаріє непомітно: поруч зі свіжим його не відрізнити. Єдине їх місце — тека {work_prefix} воркспейсу (робоча тека workPath, типово build/; гітігнорована), куди пише make Уніки (типово {ws_prefix}/build/artifacts/). Прибрати з індексу зі збереженням історії: git rm --cached <шлях> — рішення за вами, kit сам нічого не змінює.",
            ws.path,
            committed.len(),
            shown.join(", ")
        ),
    );
}

/// Аудит `v8project.local.yaml`: підключення до бази ЛЮДИНИ під ключем Уніки.
pub(super) fn local_audit(c: &mut Collector, ctx: &Context, ws: &Workspace) {
    let rel = format!("{}/v8project.local.yaml", ws.path);
    let local_path = Path::new(&ws.full_path).join("v8project.local.yaml");
    let mut local_conn = None;
    let mut read_failed = false;
    // Файл, який не вдалося прочитати, — «не перевірено» (ADR-0021 п. 2); прочитаний, але нерозібраний — error.
    match std::fs::read(&local_path) {
        Err(e) if local_path.is_file() => {
            read_failed = true;
            c.unchecked(
                "local-audit",
                &format!("{rel}: аудит підключення"),
                &e.to_string(),
            );
        }
        _ => match read_local_infobase(&local_path) {
            Ok(Some(ib)) => local_conn = Some(ib.connection),
            Ok(None) => {}
            Err(e) => c.add(
                Level::Error,
                "local-audit",
                format!("{rel} не читається: {}", e.message()),
            ),
        },
    }

    if local_conn.is_some() {
        base_collisions(c, ctx, ws, &rel);
    }

    match (&local_conn, &ctx.overlay) {
        (Some(conn), Some(_)) => dev_base_audit(c, ctx, ws, &rel, conn),
        _ => {
            if local_conn.is_some() && ctx.overlay_path.is_some() && ctx.overlay.is_none() {
                c.unchecked(
                    "local-audit",
                    &format!("{rel}: звірка бази агента з дев-базами накладки"),
                    "накладку не розібрано",
                );
            }
            // Стара конвенція `devInfobase:` (до 1.0) kit уже не читає: без цієї гілки аудит пропускався б БЕЗ
            // ЖОДНОГО РЯДКА, а «нічого не сказано» читається як «все гаразд».
            // Збій читання вже названо вище одним рядком — другого («devInfobase») не додаємо.
            if local_path.is_file() && !read_failed {
                match std::fs::read(&local_path) {
                    Err(e) => c.unchecked(
                        "local-audit",
                        &format!("{rel}: ключ devInfobase"),
                        &e.to_string(),
                    ),
                    Ok(_) => {
                        if crate::config::local_has_dev_infobase_line(ws) {
                            c.add(
                                Level::Warn,
                                "local-audit",
                                format!("{rel}: ключ devInfobase: — стара конвенція, kit її більше не читає. Дев-база має переїхати в v8storagekit.local.yaml, infobases: (перекладе скіл v8storagekit:onboarding); доти dump для цього воркспейсу не має звідки взяти базу."),
                            );
                        }
                    }
                }
            }
        }
    }
}

/// Бази агента різних воркспейсів не перетинаються (той самий перелік, що перевіряє `provision`). Пара «база проти
/// бази» симетрична — повідомляємо один раз, з воркспейсу, що йде першим за назвою (ординально).
fn base_collisions(c: &mut Collector, ctx: &Context, ws: &Workspace, rel: &str) {
    let found = match crate::config::agent_base_collisions(ctx, ws) {
        Ok(f) => f,
        Err(e) => {
            return c.add(
                Level::Error,
                "local-audit",
                format!("{rel}: звірка бази агента з базами інших воркспейсів впала: {e}"),
            );
        }
    };
    for hit in found {
        let other = hit.other.as_deref().unwrap_or_default();
        if hit.kind == CollisionKind::Base && ws.path.as_str() > other {
            continue;
        }
        let p = &ws.path;
        let detail = match hit.kind {
            CollisionKind::Base if hit.server => format!(
                "база агента воркспейсу '{p}' і база агента воркспейсу '{other}' — та сама серверна база (збігаються сервер і Ref)"
            ),
            CollisionKind::Base => format!(
                "база агента воркспейсу '{p}' перетинається з базою агента воркспейсу '{other}'"
            ),
            CollisionKind::MemoryMine => format!(
                "база агента воркспейсу '{other}' лежить у пам'яті раннера '.local/infobases/origin' воркспейсу '{p}'"
            ),
            CollisionKind::MemoryBoth => format!(
                "пам'ять раннера воркспейсу '{p}' перетинається з пам'яттю раннера воркспейсу '{other}'"
            ),
            CollisionKind::MemoryTheirs => format!(
                "база агента воркспейсу '{p}' лежить у '.local/infobases' воркспейсу '{other}'"
            ),
        };
        let one_dir = if hit.server {
            ""
        } else {
            " (одна тека, вкладена чи батьківська)"
        };
        // Kit нічого не видаляє: шкода — у тому, що створення чи завантаження бази одного воркспейсу пішло б у
        // теку (базу) іншого, а порада provision «видаліть теку» зачепила б чуже.
        let consequence = if hit.kind == CollisionKind::MemoryBoth {
            "раннер двох воркспейсів вів би пам'ять в одній теці, а порада provision видалити теку пам'яті зачепила б пам'ять іншого воркспейсу"
        } else {
            "kit створив би чи завантажив базу агента в теку (базу) іншого воркспейсу, а порада provision видалити теку бази зачепила б чужу базу"
        };
        let advice = if hit.server && same_owner(ctx.manifest.as_ref(), p, other) {
            "Обидва воркспейси мають одну конфігурацію-власника: розширення одного власника — набори одного воркспейсу з однією базою агента, тож перенесіть набір у воркспейс того самого власника (v8storagekit:infobase-agent, «Спершу власник»)."
        } else {
            "Задайте кожному воркспейсу окрему теку infobases.origin.connection (v8storagekit:infobase-agent)."
        };
        c.add(
            Level::Error,
            "local-audit",
            format!("{rel}: {detail}{one_dir} — {consequence}. {advice}"),
        );
    }
}

/// Конфігурація-власник воркспейсу — множина `dump.from` його джерел у маніфесті (так маніфест зберігає власника
/// основи). Однаковий непорожній збір у двох воркспейсів — той самий власник; без `dump.from` власника не знаємо.
fn same_owner(manifest: Option<&Manifest>, a: &str, b: &str) -> bool {
    let owner = |path: &str| -> Option<Vec<String>> {
        let ws = manifest?.workspaces.iter().find(|w| w.path == path)?;
        let mut v: Vec<String> = ws
            .sources
            .iter()
            .filter_map(|s| s.dump_from.clone())
            .collect();
        v.sort();
        v.dedup();
        (!v.is_empty()).then_some(v)
    };
    matches!((owner(a), owner(b)), (Some(x), Some(y)) if x == y)
}

/// Підключення бази агента з `v8project.local.yaml` проти дев-баз накладки — та сама формула ідентичності, що в
/// `resolve_agent_base` (`config::agent_base::dev_base_overlaps`): текстова нормалізація не бачить, що `File=D:\x\`
/// і `File=D:\x` — та сама тека. Усі збіги в порядку накладки; `Err` — fail-closed на нерозбірному.
fn dev_base_audit(
    c: &mut Collector,
    ctx: &Context,
    ws: &Workspace,
    rel: &str,
    conn: &RawConnection,
) {
    let mut reported: Vec<String> = Vec::new();
    for hit in dev_base_overlaps(ctx.overlay.as_ref(), &ws.path, &ws.project, conn) {
        let message = match hit {
            Ok(human) => format!(
                "{rel}: infobases.origin.connection збігається з дев-базою '{}' із накладки kit або перетинається з нею (та сама, вкладена чи батьківська тека) — це база людини під ключем Unica, і Уніка (push) писала б у неї. Приберіть infobases.origin звідти й дайте агентові окрему базу (v8storagekit:infobase-agent).",
                human.name
            ),
            Err(e) => format!(
                "{rel}: аудит infobases.origin.connection проти дев-баз накладки впав: {}",
                e.message()
            ),
        };
        // Нерозбірне підключення бази агента дає той самий `Err` на кожній дев-базі — один рядок, не N.
        if reported.contains(&message) {
            continue;
        }
        reported.push(message.clone());
        c.add(Level::Error, "local-audit", message);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Truth;
    use crate::config::manifest::{ManifestSource, ManifestWorkspace, ProductKind};

    fn ws(path: &str, from: Option<&str>) -> ManifestWorkspace {
        ManifestWorkspace {
            path: path.into(),
            sources: vec![ManifestSource {
                key: "base".into(),
                truth: Truth::Vendor,
                truth_text: "vendor".into(),
                storage_path: None,
                storage_user: None,
                dump_from: from.map(str::to_string),
            }],
        }
    }

    fn manifest(a: Option<&str>, b: Option<&str>) -> Manifest {
        Manifest {
            path: "v8storagekit.yaml".into(),
            version: 1,
            kind: ProductKind::Product,
            label: "x".into(),
            main_branch: "main".into(),
            workspaces: vec![ws("A", a), ws("B", b)],
            has_kit_version: false,
        }
    }

    #[test]
    fn same_dump_from_is_same_owner() {
        assert!(same_owner(
            Some(&manifest(Some("dev"), Some("dev"))),
            "A",
            "B"
        ));
    }

    #[test]
    fn different_or_missing_owner_is_not_same() {
        assert!(!same_owner(
            Some(&manifest(Some("devA"), Some("devB"))),
            "A",
            "B"
        ));
        assert!(!same_owner(Some(&manifest(None, None)), "A", "B"));
        assert!(!same_owner(None, "A", "B"));
    }
}
