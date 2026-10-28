#!/usr/bin/env python3
"""Score retained local authored receipts. Gold is never sent to the model.

These cases become development data after inspection; this is not a population
accuracy estimate. Legacy receipts have plain actions, newer ones typed fields.
"""
import json
import re
import sys
from pathlib import Path


def score(cases_path, receipts_path):
    cases = json.loads(Path(cases_path).read_text())
    rows = []
    for case in cases:
        receipt = json.loads((Path(receipts_path) / (case['id'] + '.json')).read_text())
        notes = receipt.get('notebook')
        issues = []
        if not notes:
            issues.append(receipt.get('error', 'No notebook'))
        else:
            structured = notes.get('actionResolutions')
            actions = ([x for x in structured if x['status'] == 'active'] if structured is not None
                       else [{'task': text} for text in notes['actions'].splitlines() if text.strip()])
            if len(actions) != len(case['gold']['active']):
                issues.append('Wrong active-task count')
            for expected in case['gold']['active']:
                matches = [a for a in actions if expected['taskContains'].lower() in a['task'].lower()]
                if len(matches) != 1:
                    issues.append('Missing or duplicated task: ' + expected['taskContains'])
                    continue
                actual = matches[0]
                if structured is not None:
                    if actual.get('owner') != expected['owner']:
                        issues.append('Wrong owner: ' + expected['taskContains'])
                    deadline = actual.get('deadline')
                    if expected['deadlineContains'] is None:
                        if deadline is not None:
                            issues.append('Borrowed or invented deadline: ' + expected['taskContains'])
                    elif not deadline or expected['deadlineContains'].lower() not in deadline.lower():
                        issues.append('Wrong/missing deadline: ' + expected['taskContains'])
                else:
                    text = actual['task']
                    if expected['owner'] and expected['owner'].lower() not in text.lower():
                        issues.append('Wrong/missing owner: ' + expected['taskContains'])
                    if expected['deadlineContains'] and expected['deadlineContains'].lower() not in text.lower():
                        issues.append('Wrong/missing deadline: ' + expected['taskContains'])
                    if expected['deadlineContains'] is None and re.search(r'\b(Friday|Thursday|Wednesday|Monday|Tuesday|tomorrow)\b', text, re.I):
                        issues.append('Borrowed deadline: ' + expected['taskContains'])
            for cancelled in case['gold']['cancelled']:
                if any(cancelled.lower() in a['task'].lower() for a in actions):
                    issues.append('Cancelled work remained active: ' + cancelled)
                if structured is not None and not any(x['status'] == 'cancelled' and cancelled.lower() in x['task'].lower() for x in structured):
                    issues.append('Cancellation history missing: ' + cancelled)
        rows.append({'case': case['id'], 'passed': not issues, 'issues': issues,
                     'seconds': receipt['seconds']})
    return {'cases': len(rows), 'passed': sum(x['passed'] for x in rows), 'rows': rows,
            'scope': 'Authored development checks, not a representative or unseen benchmark.'}


if __name__ == '__main__':
    result = score(sys.argv[1], sys.argv[2])
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] == result['cases'] else 1)
