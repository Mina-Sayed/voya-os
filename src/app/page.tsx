import { dashboardData } from "@/features/dashboard/dashboard-data";
import { OperationsDashboard } from "@/features/dashboard/operations-dashboard";

export default function Home() {
  return <OperationsDashboard data={dashboardData} />;
}
