import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { TransportOperationsPage, type DriverItem, type TransportRequestItem, type VehicleItem } from "@/features/transport/transport-operations-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { assignTransportRequestAction, createFleetDriverAction, createFleetVehicleAction, createTransportRequestAction, updateTransportRequestStatusAction } from "./actions";

type VehicleRow = Readonly<{ id: string; display_name: string; vehicle_type: VehicleItem["vehicleType"]; registration_code: string; passenger_capacity: number; status: VehicleItem["status"]; created_at: string }>;
type DriverRow = Readonly<{ id: string; display_name: string; phone_e164: string | null; status: DriverItem["status"]; created_at: string }>;
type RequestRow = Readonly<{ id: string; request_type: TransportRequestItem["requestType"]; status: TransportRequestItem["status"]; guest_label: string; pickup_location: string; dropoff_location: string; pickup_at: string; return_at: string | null; passenger_count: number; vehicle_id: string | null; vehicle_name: string | null; driver_id: string | null; driver_name: string | null; booking_id: string | null; notes: string | null; created_at: string; updated_at: string }>;

async function loadTransport(organizationId: string) {
  const client = await createServerSupabaseClient();
  const [vehiclesResult, driversResult, requestsResult] = await Promise.all([
    client.rpc("list_fleet_vehicles", { p_organization_id: organizationId }),
    client.rpc("list_fleet_drivers", { p_organization_id: organizationId }),
    client.rpc("list_transport_requests", { p_organization_id: organizationId, p_limit: 100 }),
  ]);
  const firstError = vehiclesResult.error ?? driversResult.error ?? requestsResult.error;
  if (firstError) throwWorkspaceOperationError("workspace.transport.read", firstError);
  return {
    vehicles: ((vehiclesResult.data ?? []) as VehicleRow[]).map((vehicle): VehicleItem => ({ id: vehicle.id, displayName: vehicle.display_name, vehicleType: vehicle.vehicle_type, registrationCode: vehicle.registration_code, passengerCapacity: vehicle.passenger_capacity, status: vehicle.status, createdAt: vehicle.created_at })),
    drivers: ((driversResult.data ?? []) as DriverRow[]).map((driver): DriverItem => ({ id: driver.id, displayName: driver.display_name, phoneE164: driver.phone_e164, status: driver.status, createdAt: driver.created_at })),
    requests: ((requestsResult.data ?? []) as RequestRow[]).map((request): TransportRequestItem => ({ id: request.id, requestType: request.request_type, status: request.status, guestLabel: request.guest_label, pickupLocation: request.pickup_location, dropoffLocation: request.dropoff_location, pickupAt: request.pickup_at, returnAt: request.return_at, passengerCount: request.passenger_count, vehicleId: request.vehicle_id, vehicleName: request.vehicle_name, driverId: request.driver_id, driverName: request.driver_name, bookingId: request.booking_id, notes: request.notes, createdAt: request.created_at, updatedAt: request.updated_at })),
  };
}

export default async function TransportWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations"]));
  const transport = await loadTransport(membership.organizationId);
  return <WorkspaceShell activeHref="/workspace/transport" organizationName={membership.organizationName} role={membership.role}><TransportOperationsPage canManageFleet={membership.role !== "sales_agent"} assignRequest={assignTransportRequestAction} createDriver={createFleetDriverAction} createRequest={createTransportRequestAction} createVehicle={createFleetVehicleAction} drivers={transport.drivers} requests={transport.requests} updateStatus={updateTransportRequestStatusAction} vehicles={transport.vehicles} /></WorkspaceShell>;
}
