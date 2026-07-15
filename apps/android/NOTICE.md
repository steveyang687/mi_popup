# Upstream attribution

The Android notification-listener flow is adapted from
[NotificationForwarder](https://github.com/ItsAzni/NotificationForwarder),
commit `b2f7e9e`, licensed under the MIT License.

This capture build removes webhook delivery, network permissions, Room and
WorkManager. It adds local JSONL rotation, target-package filtering, redacted
export and a capture-focused user interface.
