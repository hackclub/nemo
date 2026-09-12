import os, sys
from pathlib import Path
from unittest.mock import patch
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'pipeline'))
from tests import test_event_projector as t
from ingest import event_projector as ep
from psycopg.errors import LockNotAvailable
import pytest
m=pytest.MonkeyPatch()
conn=t.Conn(t.rows(2))
t.run_with(m,conn)
def record(*args):
    if args[2]=='0.0': raise LockNotAvailable('temporary lock contention')
    return True
m.setattr(ep.archive,'record',record)
ep.run(conn)
print('Transiently failed event E0 marked projected:', 'E0' in conn.marked, '(expected False)')
m.undo()
sys.path.insert(0,str(root/'proxy'))
os.environ.pop('PROXY_BUDGET',None)
with patch('dotenv.load_dotenv', side_effect=lambda *a,**k: os.environ.__setitem__('PROXY_BUDGET','observe')):
    import app
    import budget
    print('dotenv configured mode / actual budget mode:',os.environ['PROXY_BUDGET'],budget.MODE,'(expected observe / observe)')
