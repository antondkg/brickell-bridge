#!/usr/bin/env python3
"""Build the "Bridge Status" iOS Shortcut: fetch /v1/summary, show it as a notification, and output it
so Siri reads it aloud ("Hey Siri, Bridge Status"). Run from an automation, the output goes nowhere.

Run on a Mac signed in to iCloud:  python3 build_shortcut.py
Produces ../api/public/bridge-status.shortcut (signed, importable on any iPhone).
"""
import plistlib
import subprocess
import uuid
from pathlib import Path

URL = "https://api.brickellbridge.fun/v1/summary?format=json"
OUT = Path(__file__).resolve().parent.parent / "api" / "public" / "bridge-status.shortcut"


def output(uid, name):
    return {"OutputUUID": uid, "Type": "ActionOutput", "OutputName": name}


def token_string(attachment):
    return {"Value": {"string": "￼", "attachmentsByRange": {"{0, 1}": attachment}}, "WFSerializationType": "WFTextTokenString"}


def token_attachment(attachment):
    return {"Value": attachment, "WFSerializationType": "WFTextTokenAttachment"}


fetch, title, body = (str(uuid.uuid4()).upper() for _ in range(3))
actions = [
    {"WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
     "WFWorkflowActionParameters": {"UUID": fetch, "WFURL": URL, "WFHTTPMethod": "GET"}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
     "WFWorkflowActionParameters": {"UUID": title, "WFDictionaryKey": "title", "WFGetDictionaryValueType": "Value",
                                    "WFInput": token_attachment(output(fetch, "Contents of URL"))}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.getvalueforkey",
     "WFWorkflowActionParameters": {"UUID": body, "WFDictionaryKey": "body", "WFGetDictionaryValueType": "Value",
                                    "WFInput": token_attachment(output(fetch, "Contents of URL"))}},
    {"WFWorkflowActionIdentifier": "is.workflow.actions.notification",
     "WFWorkflowActionParameters": {"WFNotificationActionTitle": token_string(output(title, "Dictionary Value")),
                                    "WFNotificationActionBody": token_string(output(body, "Dictionary Value")),
                                    "WFNotificationActionSound": True}},
    # Siri speaks a shortcut's output; without this it just says "Done".
    {"WFWorkflowActionIdentifier": "is.workflow.actions.output",
     "WFWorkflowActionParameters": {"WFOutput": token_string(output(body, "Dictionary Value")),
                                    "WFNoOutputSurfaceBehavior": "Do Nothing"}},
]
workflow = {
    "WFWorkflowName": "Bridge Status",
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "2605.0.5",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowTypes": [],
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowImportQuestions": [],
    "WFQuickActionSurfaces": [],
    "WFWorkflowHasShortcutInputVariables": False,
}

unsigned = OUT.with_suffix(".unsigned.shortcut")
unsigned.write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY))
subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(unsigned), "--output", str(OUT)], check=True)
unsigned.unlink()
print("wrote", OUT, OUT.stat().st_size, "bytes")
