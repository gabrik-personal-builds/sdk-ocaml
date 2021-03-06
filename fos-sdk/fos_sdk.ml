(*********************************************************************************
 * Copyright (c) 2018 ADLINK Technology Inc.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0, or the Apache Software License 2.0
 * which is available at https://www.apache.org/licenses/LICENSE-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0 OR Apache-2.0
 * Contributors: 1
 *   Gabriele Baldoni (gabriele (dot) baldoni (at) adlinktech (dot) com ) - OCaml implementation
 *********************************************************************************)

module Str = Re.Str
module MVar = Apero.MVar_lwt



module FAgentTypes = Agent_types
(* module FAgentTypesJson = Agent_types *)
module FAgentTypesValidator = Agent_types_v

module FTypes = Fos_types
module FTypesRecord = Fos_records_types
module FTypesValidator = Fos_types_v
module JSON = Abs_json



module Errors = Fos_errors
(* module FDU = Fdu *)
module Router = Router

(* module AtomicEntity = Atomic_entity *)

module MEC = Mec
module NFV = Nfv
module MEC_Interfaces = Mec_interfaces


(* Exporting Modules in Tree strucutre *)


module Base = struct
  module Descriptors = struct
    module FDU = Base_fdu
    module AtomicEnitity = Base_atomic_entity
    module Entity = Base_entity
    module Network = Base_network
  end
end

module User  = struct
  module Descriptors = struct
    module FDU = User_fdu
    module AtomicEntity = User_atomic_entity
    module Entity = User_entity
    module Network = User_network
  end
end

module Infra = struct
  module Descriptors = struct
    module Router = Router
    module FDU = Infra_fdu
    module AtomicEntity = Infra_atomic_entity
    module Entity = Infra_entity
    module Network = Infra_network
  end
end



module ConstraintMap = Map.Make(String)

let string_of_hv_type (kind:Infra_fdu.hv_kind) =
  match kind with
  | `BARE -> "native"
  | `KVM | `KVM_UK -> "kvm"
  | `XEN | `XEN_UK -> "xen"
  | `LXD -> "lxd"
  | `DOCKER -> "docker"
  | `MCU -> "mcu"
  | `ROS2 -> "ros2"

let hv_type_of_string hv =
  match hv with
  | "native" -> `BARE
  | "kvm" -> `KVM
  | "xen" -> `XEN
  | "lxd" -> `LXD
  | "docker" -> `DOCKER
  | "mcu" -> `MCU
  | "ros2" -> `ROS2
  | _ -> raise @@ Errors.FException (`InformationModelError (`Msg ( Printf.sprintf "Hypervisor %s not recognized" hv)))



let fdu_of_mecapp (mecapp:MEC.appd_descriptor) =
  let id = mecapp.id in
  let name = mecapp.name in
  let hypervisor = List.hd mecapp.sw_image_descriptor.supported_virtualisation_environment |> hv_type_of_string in
  let migration_kind = `LIVE in
  let io_ports = [] in
  let depends_on = [] in
  let interfaces = [
    User_fdu.{
      name = "eth0";
      is_mgmt = false;
      if_type = `INTERNAL;
      mac_address = None;
      virtual_interface = {
        intf_type = `VIRTIO;
        vpci = "0:0:0";
        bandwidth = 100;
      };
      cp_id = None;
      ext_cp_id = None;
    };
    User_fdu.{
      name = "eth1";
      is_mgmt = true;
      if_type = `INTERNAL;
      mac_address = None;
      virtual_interface = {
        intf_type = `VIRTIO;
        vpci = "0:0:0";
        bandwidth = 100;
      };
      cp_id = None;
      ext_cp_id = None;
    };
  ]
  in
  let computation_requirements = Base_fdu.{
      uuid = None;
      name = None;
      cpu_arch = mecapp.virtual_compute_descriptor.virtual_cpu.cpu_architecture;
      cpu_min_freq = Apero.Option.get_or_default mecapp.virtual_compute_descriptor.virtual_cpu.virtual_cpu_clock 0;
      cpu_min_count = mecapp.virtual_compute_descriptor.virtual_cpu.num_virtual_cpu;
      ram_size_mb = float_of_int @@ mecapp.virtual_compute_descriptor.virtual_memory.virtual_mem_size;
      storage_size_gb =  float_of_int @@ mecapp.sw_image_descriptor.min_disk;
      gpu_min_count = None;
      fpga_min_count = None;
      duty_cycle = None;
    }
  in
  let image = Base_fdu.{
      uuid = None;
      name = None;
      uri = mecapp.sw_image_descriptor.id;
      checksum = mecapp.sw_image_descriptor.checksum;
      format = mecapp.sw_image_descriptor.disk_format;
    }
  in
  User_fdu.create_descriptor ~id ~name ~hypervisor ~image ~computation_requirements ~migration_kind ~io_ports ~depends_on ~interfaces

type configuration  = FAgentTypes.configuration

type system_status = {

  mutable tenants : FAgentTypes.tenant_type list;
  mutable users :  FAgentTypes.user_type list;
}

let contains s1 s2 =
  try
    let len = String.length s2 in
    for i = 0 to String.length s1 - len do
      if String.sub s1 i len = s2 then raise Exit
    done;
    false
  with Exit -> true

let replace input output = Str.global_replace (Str.regexp_string input) output

let rec read_from_ic s ic =
  try
    let s = s ^ input_line ic in
    read_from_ic s ic
  with
  | End_of_file -> s


let string_split token data =
  String.split_on_char token data

let read_file path =
  let ic = Pervasives.open_in path in
  let data = read_from_ic "" ic in
  let _ = close_in ic in
  data


let get_platform () =
  try
    let ic = Unix.open_process_in "uname" in
    let uname = input_line ic in
    let _ = close_in ic in
    uname
  with
  | _ -> "windows"


let get_unix_syslog_reporter () =
  match String.uppercase_ascii @@ get_platform () with
  | "LINUX" ->
    (Apero.Result.get (Logs_syslog_unix.unix_reporter ()))
  | "DARWIN" ->
    (Apero.Result.get (Logs_syslog_unix.unix_reporter ~socket:"/var/run/syslog"  ()))
  | "WINDOWS" -> (Apero.Result.get (Logs_syslog_unix.unix_reporter ()))
  | _ -> failwith "[ ERRO ] Operating System not recognized!"


let getuuid (uuid:string option) () =
  match uuid with
  | Some id -> id
  | None ->
    (match String.uppercase_ascii @@ get_platform () with
     | "LINUX" ->
       let fname = "/etc/machine-id" in
       let ic = Pervasives.open_in fname in
       let uuid = input_line ic in
       let _ = close_in ic in
       (match String.index_opt uuid '-' with
        | Some _ ->  uuid
        | None ->  String.sub uuid 0 8 ^ "-" ^ String.sub uuid 8 4 ^ "-" ^ String.sub uuid 12 4 ^ "-" ^ String.sub uuid 16 4 ^ "-" ^ String.sub uuid 20 12)
     | "DARWIN" ->
       let ic = Unix.open_process_in "ioreg -rd1 -c IOPlatformExpertDevice |  awk '/IOPlatformUUID/ { print $3; }'" in
       let uuid = input_line ic in
       let _ = close_in ic in
       String.sub uuid 1 ((String.length uuid)-2)
     | "WINDOWS" ->
       (* uuid_regex = r"UUID.+\r\r\n(.{0,36})"
          p = psutil.Popen('wmic csproduct get UUID'.split(), stdout=PIPE)
          uuid is group 1
       *)
       ""
     | _ -> failwith "[ ERRO ] Operating System not recognized!")


let load_config filename customid =
  let cont = read_file filename in
  let conf = FAgentTypes.configuration_of_string cont in
  let conf =
    match conf.agent.uuid with
    | Some _ -> conf
    | None -> {conf with agent = {conf.agent with uuid = Some( getuuid  customid () )} }
  in
  conf


let config_to_json config =
  FAgentTypes.string_of_configuration config