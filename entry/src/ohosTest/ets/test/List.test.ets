import persistenceTest from './Persistence.test';
import syncPolicyTest from '../../../test/SyncPolicy.test';

export default function testsuite() {
  persistenceTest();
  syncPolicyTest();
}
