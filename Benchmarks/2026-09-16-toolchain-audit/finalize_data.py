#!/usr/bin/env python3
"""Validate complete campaigns and derive tables without changing raw observations."""
import csv
import json
from pathlib import Path
from analyze_logs import analyze
from phase_metrics import run as phase_run
from summarize import summarize

HERE=Path(__file__).resolve().parent
RAW=HERE/'raw'
EXPECTED={'main-mine':24,'followup45-mine':12,'production-batch-mine':12,'sustained-mine':1}
summaries=[];validation=[];phases=[];rows=[]
for name,count in EXPECTED.items():
    directory=RAW/name
    summary=summarize(directory)
    assert len(summary['runs'])==count,(name,len(summary['runs']),count)
    summaries.append(summary)
    (RAW/(name.removesuffix('-mine')+'-summary.json')).write_text(json.dumps(summary,indent=2)+'\n')
    for row in summary['runs']:
        metadata=directory/row['file']
        events=metadata.with_name(metadata.name.removesuffix('.metadata.json')+'.events.ndjson')
        checks=analyze(events)
        assert len(checks['sessions'])==1
        session=checks['sessions'][0]
        issues=session['chronology_and_monotonicity_issues']
        # These three exported values are differences of accumulated measures, not
        # independently accumulated counters. Preserve every decrease, while
        # checking all underlying monotonic counters and rate identities.
        derived=[x for x in issues if x.startswith(('nonmonotonic gpu_build_command_non_gpu_seconds_total:',
                                                    'nonmonotonic gpu_search_command_non_gpu_seconds_total:',
                                                    'nonmonotonic gpu_search_command_non_gpu_busy_seconds_total:'))]
        other=[x for x in issues if x not in derived]
        assert not other,(name,row['file'],other)
        assert row['protocol_errors']==0 and row['dataset_bytes']==7_272_058_080
        final=session['final_fields']
        assert int(final['shares_rejected'])==0
        assert int(final['dataset_cold_builds_failed_total'])==0
        validation.append(dict(campaign=name,file=row['file'],sessionID=session['sessionID'],
            invariant_residuals=session['invariant_residuals'],derived_counter_decreases=derived,
            base_counter_and_chronology_issues=other,protocol_errors=row['protocol_errors'],
            dataset_build_failures=int(final['dataset_cold_builds_failed_total'])))
        phase=phase_run(metadata);phase['campaign']=name;phases.append(phase)
        builds=row['builds'];search=phase['phases']['searching']
        rows.append(dict(campaign=name,run=row['file'].split('-')[0],variant=row['variant'],batch=row['batch'],
            elapsed_seconds=row['elapsed'],nonces=row['nonces'],search_seconds=row['search_seconds'],
            active_mhs=row['active_mhs'],effective_mhs=row['effective_mhs'],search_duty=row['search_duty'],
            cold_build_wall=float(builds[0]['seconds']),cold_build_gpu=float(builds[0]['gpu_seconds']),
            warm_build_wall=';'.join(b['seconds'] for b in builds[1:]),
            warm_build_gpu=';'.join(b['gpu_seconds'] for b in builds[1:]),
            start_temperature=row['start_temperature'],sample_temperature_median=row['sample_temperature']['median'],
            peak_temperature=row['peak_temperature'],cpu_percent_one_core=row['cpu_percent_one_core'],
            non_gpu_search_busy_seconds=row['non_gpu_search_busy_seconds'],
            search_gpu_w_mean=search['gpu_w']['mean'] if search['gpu_w'] else None,
            search_gpu_mhz_mean=search['gpu_mhz']['mean'] if search['gpu_mhz'] else None,
            search_gpu_active_percent=search['gpu_active_percent']['mean'] if search['gpu_active_percent'] else None))
(RAW/'all-campaign-summaries.json').write_text(json.dumps(summaries,indent=2)+'\n')
(RAW/'controlled-session-validation.json').write_text(json.dumps(validation,indent=2)+'\n')
(RAW/'all-phase-metrics.json').write_text(json.dumps(phases,indent=2)+'\n')
with (RAW/'all-runs.csv').open('w') as output:
    writer=csv.DictWriter(output,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
print(f'{len(rows)} completed sessions validated; raw observations unchanged.')
