# Changelog

## 1.3.1

- Widgets show fresh quotas as soon as they arrive, instead of a few
  seconds later, and Prism checks on them less often while they wait.

## 1.3.0

- In Simplified or Traditional Chinese, the list, detail pane, widgets,
  quota labels, reset times, and sign-in and error messages are in Chinese
  too. Agent and plan names stay as each service writes them.

## 1.2.0

- When Prism runs in Simplified or Traditional Chinese, it shows this
  extension's name, description, command, settings, and widgets in that
  language, and Chinese words find its command in search.

## 1.1.0

- Runs as its own process, built with PrismExtensionKit, instead of inside
  Prism. The list, detail, widgets, and settings are unchanged.
- Keeps the last results and the refresh throttle in its data folder, so a
  restarted process shows them at once without fetching again.
- Brand icons ship with the extension.
