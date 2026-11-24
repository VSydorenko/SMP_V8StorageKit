// Групи шляхів, що різняться лише регістром (`Get-KitCaseCollisions`, tools/lib/CaseGuard.psm1): складання за
// юнікодним `OrdinalIgnoreCase`, як у NTFS. `core.ignorecase` у git складає лише a–z, тому кириличну пару git
// вважає двома файлами, а NTFS — одним; ASCII-складання дало б на кирилиці хибне «колізій немає».

use std::collections::{BTreeSet, HashMap};

/// Простий верхній регістр посимвольно (без розширення довжини) — як `OrdinalIgnoreCase`.
pub(crate) fn fold(path: &str) -> String {
    path.chars()
        .map(|c| {
            let mut up = c.to_uppercase();
            match (up.next(), up.next()) {
                (Some(x), None) => x,
                _ => c,
            }
        })
        .collect()
}

/// Групи (по два шляхи й більше), що збігаються без регістру: усередині групи й між групами — ординальний порядок.
pub fn case_collisions(paths: &[String]) -> Vec<Vec<String>> {
    let mut map: HashMap<String, BTreeSet<&str>> = HashMap::new();
    for p in paths {
        map.entry(fold(p)).or_default().insert(p.as_str());
    }
    let mut groups: Vec<Vec<String>> = map
        .into_values()
        .filter(|set| set.len() > 1)
        .map(|set| set.into_iter().map(str::to_string).collect())
        .collect();
    groups.sort();
    groups
}

#[cfg(test)]
mod tests {
    use super::case_collisions;

    #[test]
    fn groups_cyrillic_pairs_and_sorts_ordinally() {
        let paths: Vec<String> = ["b/Файл.xml", "b/файл.xml", "a/X", "a/x", "c/y"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let groups = case_collisions(&paths);
        assert_eq!(
            groups,
            vec![
                vec!["a/X".to_string(), "a/x".to_string()],
                vec!["b/Файл.xml".to_string(), "b/файл.xml".to_string()],
            ]
        );
        assert!(case_collisions(&["a".to_string(), "a".to_string()]).is_empty());
    }
}
