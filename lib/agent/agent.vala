namespace Frida.Agent {
	public void main (string agent_parameters, ref Frida.UnloadPolicy unload_policy, void * injector_state) {
		if (Runner.shared_instance == null)
			Runner.create_and_run (agent_parameters, ref unload_policy, injector_state);
		else
			Runner.resume_after_fork (ref unload_policy, injector_state);
	}

	private enum StopReason {
		UNLOAD,
		FORK
	}

	private class Runner : Object, ProcessInvader, AgentSessionProvider, ExitHandler, ForkHandler, SpawnHandler {
		public static Runner shared_instance = null;
		public static Mutex shared_mutex;

		public string agent_parameters {
			get;
			construct;
		}

		public string? agent_path {
			get;
			construct;
		}

		public StopReason stop_reason {
			get;
			set;
			default = UNLOAD;
		}

		public bool is_eternal {
			get {
				return _is_eternal;
			}
		}
		private bool _is_eternal = false;

		private bool stop_thread_on_unload = true;

		private void * agent_pthread;
		private Thread<bool> agent_gthread;

		private MainContext main_context;
		private MainLoop main_loop;
		private DBusConnection connection;
		private AgentController controller;
		private bool unloading = false;
		private uint filter_id = 0;
		private uint registration_id = 0;
		private uint pending_calls = 0;
		private Promise<bool> pending_close;
		private Gee.HashMap<AgentSessionId?, AgentClient> clients =
			new Gee.HashMap<AgentSessionId?, AgentClient> (AgentSessionId.hash, AgentSessionId.equal);
		private Gee.HashMap<DBusConnection, DirectConnection> direct_connections =
			new Gee.HashMap<DBusConnection, DirectConnection> ();
		private Gee.ArrayList<Gum.Script> eternalized_scripts = new Gee.ArrayList<Gum.Script> ();
		private Gee.HashMap<AgentSessionId?, uint> emulated_session_registrations = new Gee.HashMap<AgentSessionId?, uint> ();

		private Gum.MemoryRange agent_range;
		private Gum.ScriptBackend? qjs_backend;
		private Gum.ScriptBackend? v8_backend;
		private ExitMonitor exit_monitor;
		private Gum.Interceptor interceptor;
		private Gum.Exceptor exceptor;

		private uint child_gating_subscriber_count = 0;
		private ForkMonitor? fork_monitor;
		private FileDescriptorGuard fd_guard;
		private ThreadListCloaker? thread_list_cloaker;
		private FDListCloaker? fd_list_cloaker;
		private uint fork_parent_pid;
		private uint fork_child_pid;
		private HostChildId fork_child_id;
		private uint fork_parent_injectee_id;
		private uint fork_child_injectee_id;
		private Socket fork_child_socket;
		private ForkRecoveryState fork_recovery_state;
		private Mutex fork_mutex;
		private Cond fork_cond;
		private SpawnMonitor spawn_monitor;
		private ThreadSuspendMonitor thread_suspend_monitor;

		private delegate void CompletionNotify ();

		private enum ForkRecoveryState {
			RECOVERING,
			RECOVERED
		}

		private enum ForkActor {
			PARENT,
			CHILD
		}

		public static void create_and_run (string agent_parameters, ref Frida.UnloadPolicy unload_policy,
				void * opaque_injector_state) {
			Environment._init ();

			{
				Gum.MemoryRange? mapped_range = null;

#if DARWIN
				var injector_state = (DarwinInjectorState *) opaque_injector_state;
				if (injector_state != null)
					mapped_range = injector_state.mapped_range;
#endif

				string? agent_path;
				var agent_range = detect_own_range_and_path (mapped_range, out agent_path);
				Gum.Cloak.add_range (agent_range);

				var fdt_padder = FileDescriptorTablePadder.obtain ();

#if LINUX
				var injector_state = (LinuxInjectorState *) opaque_injector_state;
				if (injector_state != null) {
					fdt_padder.move_descriptor_if_needed (ref injector_state.fifo_fd);
					Gum.Cloak.add_file_descriptor (injector_state.fifo_fd);
				}
#endif

				var ignore_scope = new ThreadIgnoreScope ();

				shared_instance = new Runner (agent_parameters, agent_path, agent_range);

				try {
					shared_instance.run ((owned) fdt_padder);
				} catch (Error e) {
					printerr ("Unable to start agent: %s\n", e.message);
				}

				if (shared_instance.stop_reason == FORK) {
#if LINUX
					if (injector_state != null)
						Gum.Cloak.remove_file_descriptor (injector_state.fifo_fd);
#endif
					unload_policy = DEFERRED;
					return;
				} else if (shared_instance.is_eternal) {
					unload_policy = RESIDENT;
					shared_instance.keep_running_eternalized ();
					return;
				} else {
					release_shared_instance ();
				}

				ignore_scope = null;
			}

			Environment._deinit ();
		}

		public static void resume_after_fork (ref Frida.UnloadPolicy unload_policy, void * opaque_injector_state) {
			{
#if LINUX
				var injector_state = (LinuxInjectorState *) opaque_injector_state;
				if (injector_state != null) {
					FileDescriptorTablePadder.obtain ().move_descriptor_if_needed (ref injector_state.fifo_fd);
					Gum.Cloak.add_file_descriptor (injector_state.fifo_fd);
				}
#endif

				var ignore_scope = new ThreadIgnoreScope ();

				shared_instance.run_after_fork ();

				if (shared_instance.stop_reason == FORK) {
#if LINUX
					if (injector_state != null)
						Gum.Cloak.remove_file_descriptor (injector_state.fifo_fd);
#endif
					unload_policy = DEFERRED;
					return;
				} else if (shared_instance.is_eternal) {
					unload_policy = RESIDENT;
					shared_instance.keep_running_eternalized ();
					return;
				} else {
					release_shared_instance ();
				}

				ignore_scope = null;
			}

			Environment._deinit ();
		}

		private static void release_shared_instance () {
			shared_mutex.lock ();
			var instance = shared_instance;
			shared_instance = null;
			shared_mutex.unlock ();

			instance = null;
		}

		private Runner (string agent_parameters, string? agent_path, Gum.MemoryRange agent_range) {
			Object (agent_parameters: agent_parameters, agent_path: agent_path);

			this.agent_range = agent_range;
		}

		construct {
			agent_pthread = get_current_pthread ();

			main_context = MainContext.default ();
			main_loop = new MainLoop (main_context);

			var interceptor = Gum.Interceptor.obtain ();
			interceptor.begin_transaction ();

			exit_monitor = new ExitMonitor (this, main_context);
			thread_suspend_monitor = new ThreadSuspendMonitor (this);

			this.interceptor = interceptor;
			this.exceptor = Gum.Exceptor.obtain ();

			interceptor.end_transaction ();
		}

		~Runner () {
			var interceptor = this.interceptor;
			interceptor.begin_transaction ();

			disable_child_gating ();

			thread_suspend_monitor = null;

			exceptor = null;

			exit_monitor = null;

			interceptor.end_transaction ();
		}

		private void run (owned FileDescriptorTablePadder padder) throws Error {
			main_context.push_thread_default ();

			start.begin ((owned) padder);

			main_loop.run ();

			main_context.pop_thread_default ();
		}

		private async void start (owned FileDescriptorTablePadder padder) {
			string[] tokens = agent_parameters.split ("|");
			unowned string transport_uri = tokens[0];
			foreach (unowned string option in tokens[1:]) {
				if (option == "eternal")
					ensure_eternalized ();
				else if (option == "sticky")
					stop_thread_on_unload = false;
			}

			yield setup_connection_with_transport_uri (transport_uri);

			Gum.ScriptBackend.get_scheduler ().push_job_on_js_thread (Priority.DEFAULT, () => {
				schedule_idle (start.callback);
			});
			yield;

			padder = null;
		}

		private void keep_running_eternalized () {
			agent_gthread = new Thread<bool> ("frida-eternal-agent", () => {
				var ignore_scope = new ThreadIgnoreScope ();

				main_context.push_thread_default ();
				main_loop.run ();
				main_context.pop_thread_default ();

				ignore_scope = null;

				return true;
			});
		}

		private async void prepare_to_exit () {
			yield prepare_for_termination (TerminationReason.EXIT);
		}

		private void run_after_fork () {
			fork_mutex.lock ();
			fork_mutex.unlock ();

			stop_reason = UNLOAD;
			agent_pthread = get_current_pthread ();

			main_context.push_thread_default ();
			main_loop.run ();
			main_context.pop_thread_default ();
		}

		private void prepare_to_fork () {
			var fdt_padder = FileDescriptorTablePadder.obtain ();

			schedule_idle (() => {
				do_prepare_to_fork.begin ();
				return false;
			});
			if (agent_gthread != null) {
				agent_gthread.join ();
				agent_gthread = null;
			} else {
				join_pthread (agent_pthread);
			}
			agent_pthread = null;

#if !WINDOWS
			GumJS.prepare_to_fork ();
			Gum.prepare_to_fork ();
			GIOFork.prepare_to_fork ();
			GLibFork.prepare_to_fork ();

#endif

			fdt_padder = null;
		}

		private async void do_prepare_to_fork () {
			stop_reason = FORK;

#if !WINDOWS
			if (controller != null) {
				try {
					fork_parent_pid = get_process_id ();
					fork_child_id = yield controller.prepare_to_fork (fork_parent_pid, null,
						out fork_parent_injectee_id, out fork_child_injectee_id, out fork_child_socket);
				} catch (GLib.Error e) {
#if ANDROID
					error ("Oops, SELinux rule probably missing for your system. Symptom: %s", e.message);
#else
					error ("%s", e.message);
#endif
				}
			}
#endif

			main_loop.quit ();
		}

		private void recover_from_fork_in_parent () {
			recover_from_fork (ForkActor.PARENT, null);
		}

		private void recover_from_fork_in_child (string? identifier) {
			recover_from_fork (ForkActor.CHILD, identifier);
		}

		private void recover_from_fork (ForkActor actor, string? identifier) {
			var fdt_padder = FileDescriptorTablePadder.obtain ();

			if (actor == PARENT) {
#if !WINDOWS
				GLibFork.recover_from_fork_in_parent ();
				GIOFork.recover_from_fork_in_parent ();
				Gum.recover_from_fork_in_parent ();
				GumJS.recover_from_fork_in_parent ();
#endif
			} else if (actor == CHILD) {
#if !WINDOWS
				GLibFork.recover_from_fork_in_child ();
				GIOFork.recover_from_fork_in_child ();
				Gum.recover_from_fork_in_child ();
				GumJS.recover_from_fork_in_child ();
#endif

				fork_child_pid = get_process_id ();

				acquire_child_gating ();

				discard_connections ();
			}

			fork_mutex.lock ();

			fork_recovery_state = RECOVERING;

			schedule_idle (() => {
				recreate_agent_thread.begin (actor);
				return false;
			});

			main_context.push_thread_default ();
			main_loop.run ();
			main_context.pop_thread_default ();

			schedule_idle (() => {
				finish_recovery_from_fork.begin (actor, identifier);
				return false;
			});

			while (fork_recovery_state != RECOVERED)
				fork_cond.wait (fork_mutex);

			fork_mutex.unlock ();

			fdt_padder = null;
		}

		private async void recreate_agent_thread (ForkActor actor) {
			uint pid, injectee_id;
			if (actor == PARENT) {
				pid = fork_parent_pid;
				injectee_id = fork_parent_injectee_id;
			} else if (actor == CHILD) {
				yield flush_all_clients ();

				if (fork_child_socket != null) {
					var stream = SocketConnection.factory_create_connection (fork_child_socket);
					yield setup_connection_with_stream (stream);
				}

				pid = fork_child_pid;
				injectee_id = fork_child_injectee_id;
			} else {
				assert_not_reached ();
			}

			if (controller != null) {
				try {
					yield controller.recreate_agent_thread (pid, injectee_id, null);
				} catch (GLib.Error e) {
					assert_not_reached ();
				}
			} else {
				agent_gthread = new Thread<bool> ("frida-eternal-agent", () => {
					var ignore_scope = new ThreadIgnoreScope ();
					run_after_fork ();
					ignore_scope = null;

					return true;
				});
			}

			main_loop.quit ();
		}

		private async void finish_recovery_from_fork (ForkActor actor, string? identifier) {
			if (actor == CHILD && controller != null) {
				var info = HostChildInfo (fork_child_pid, fork_parent_pid, ChildOrigin.FORK);
				if (identifier != null)
					info.identifier = identifier;

				var controller_proxy = controller as DBusProxy;
				var previous_timeout = controller_proxy.get_default_timeout ();
				controller_proxy.set_default_timeout (int.MAX);
				try {
					yield controller.wait_for_permission_to_resume (fork_child_id, info, null);
				} catch (GLib.Error e) {
					// The connection will/did get closed and we will unload...
				}
				controller_proxy.set_default_timeout (previous_timeout);
			}

			if (actor == CHILD)
				release_child_gating ();

			fork_parent_pid = 0;
			fork_child_pid = 0;
			fork_child_id = HostChildId (0);
			fork_parent_injectee_id = 0;
			fork_child_injectee_id = 0;
			fork_child_socket = null;

			fork_mutex.lock ();
			fork_recovery_state = RECOVERED;
			fork_cond.signal ();
			fork_mutex.unlock ();
		}

		private async void prepare_to_exec (HostChildInfo * info) {
			yield prepare_for_termination (TerminationReason.EXEC);

			if (controller == null)
				return;

			try {
				yield controller.prepare_to_exec (*info, null);
			} catch (GLib.Error e) {
			}
		}

		private async void cancel_exec (uint pid) {
			unprepare_for_termination ();

			if (controller == null)
				return;

			try {
				yield controller.cancel_exec (pid, null);
			} catch (GLib.Error e) {
			}
		}

		private async void acknowledge_spawn (HostChildInfo * info, SpawnStartState start_state) {
			if (controller == null)
				return;

			try {
				yield controller.acknowledge_spawn (*info, start_state, null);
			} catch (GLib.Error e) {
			}
		}

		public Gum.MemoryRange get_memory_range () {
			return agent_range;
		}

		public Gum.ScriptBackend get_script_backend (ScriptRuntime runtime) throws Error {
			switch (runtime) {
				case DEFAULT:
					break;
				case QJS:
					if (qjs_backend == null) {
						qjs_backend = Gum.ScriptBackend.obtain_qjs ();
						if (qjs_backend == null) {
							throw new Error.NOT_SUPPORTED (
								"QuickJS runtime not available due to build configuration");
						}
					}
					return qjs_backend;
				case V8:
					if (v8_backend == null) {
						v8_backend = Gum.ScriptBackend.obtain_v8 ();
						if (v8_backend == null) {
							throw new Error.NOT_SUPPORTED (
								"V8 runtime not available due to build configuration");
						}
					}
					return v8_backend;
			}

			try {
				return get_script_backend (QJS);
			} catch (Error e) {
			}
			return get_script_backend (V8);
		}

		public Gum.ScriptBackend? get_active_script_backend () {
			return (v8_backend != null) ? v8_backend : qjs_backend;
		}

		private async void open (AgentSessionId id, Realm realm, Cancellable? cancellable) throws Error, IOError {
			if (unloading)
				throw new Error.INVALID_OPERATION ("Agent is unloading");

			if (realm == EMULATED) {
				AgentSessionProvider emulated_provider = yield get_emulated_provider (cancellable);

				try {
					yield emulated_provider.open (id, Realm.NATIVE, cancellable);
				} catch (GLib.Error e) {
					throw_dbus_error (e);
				}

				var emulated_connection = ((DBusProxy) emulated_provider).get_connection ();

				string path = ObjectPath.from_agent_session_id (id);

				AgentSession emulated_session = yield emulated_connection.get_proxy (null, path, DBusProxyFlags.NONE,
					cancellable);

				var registration_id = connection.register_object (path, emulated_session);
				emulated_session_registrations[id] = registration_id;

				return;
			}

			var client = new AgentClient (this, id);
			clients[id] = client;
			client.closed.connect (on_client_closed);
			client.script_eternalized.connect (on_script_eternalized);

			try {
				AgentSession session = client;
				client.registration_id = connection.register_object (ObjectPath.from_agent_session_id (id), session);
			} catch (IOError io_error) {
				assert_not_reached ();
			}

			opened (id);
		}

		private async void close_all_clients () {
			uint pending = 1;

			CompletionNotify on_complete = () => {
				pending--;
				if (pending == 0)
					schedule_idle (close_all_clients.callback);
			};

			foreach (var client in clients.values.to_array ()) {
				pending++;
				close_client.begin (client, on_complete);
			}

			on_complete ();

			yield;

			assert (clients.is_empty);
		}

		private async void close_client (AgentClient client, CompletionNotify on_complete) {
			try {
				yield client.close (null);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}

			on_complete ();
		}

		private async void flush_all_clients () {
			uint pending = 1;

			CompletionNotify on_complete = () => {
				pending--;
				if (pending == 0)
					schedule_idle (flush_all_clients.callback);
			};

			foreach (var client in clients.values.to_array ()) {
				pending++;
				flush_client.begin (client, on_complete);
			}

			on_complete ();

			yield;
		}

		private async void flush_client (AgentClient client, CompletionNotify on_complete) {
			yield client.flush ();

			on_complete ();
		}

		private void on_client_closed (AgentClient client) {
			closed (client.id);

			var id = client.registration_id;
			if (id != 0) {
				connection.unregister_object (id);
				client.registration_id = 0;
			}

			client.script_eternalized.disconnect (on_script_eternalized);
			client.closed.disconnect (on_client_closed);
			clients.unset (client.id);

			foreach (var dc in direct_connections.values) {
				if (dc.client == client) {
					detach_and_steal_direct_dbus_connection (dc.connection);
					break;
				}
			}
		}

		private void on_script_eternalized (Gum.Script script) {
			eternalized_scripts.add (script);
			ensure_eternalized ();
		}

#if !WINDOWS
		private async void migrate (AgentSessionId id, Socket to_socket, Cancellable? cancellable) throws Error, IOError {
			if (emulated_session_registrations.has_key (id)) {
				AgentSessionProvider emulated_provider = yield get_emulated_provider (cancellable);
				try {
					yield emulated_provider.migrate (id, to_socket, cancellable);
				} catch (GLib.Error e) {
					throw_dbus_error (e);
				}
				return;
			}

			if (!clients.has_key (id))
				throw new Error.INVALID_ARGUMENT ("Invalid session ID");
			var client = clients[id];

			var dc = new DirectConnection (client);

			DBusConnection connection;
			try {
				connection = yield new DBusConnection (SocketConnection.factory_create_connection (to_socket),
					ServerGuid.AGENT_SESSION, AUTHENTICATION_SERVER | AUTHENTICATION_ALLOW_ANONYMOUS |
					DELAY_MESSAGE_PROCESSING, null, cancellable);
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("%s", e.message);
			}
			dc.connection = connection;

			try {
				AgentSession session = client;
				dc.registration_id = connection.register_object (ObjectPath.AGENT_SESSION, session);
			} catch (IOError io_error) {
				assert_not_reached ();
			}

			connection.start_message_processing ();

			this.connection.unregister_object (client.registration_id);
			client.registration_id = 0;

			direct_connections[connection] = dc;
			connection.on_closed.connect (on_direct_connection_closed);
		}
#endif

		private void on_direct_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			var dc = detach_and_steal_direct_dbus_connection (connection);

			dc.client.close.begin (null);
		}

		private DirectConnection detach_and_steal_direct_dbus_connection (DBusConnection connection) {
			connection.on_closed.disconnect (on_direct_connection_closed);

			DirectConnection dc;
			bool found = direct_connections.unset (connection, out dc);
			assert (found);

			connection.unregister_object (dc.registration_id);

			return dc;
		}

		private async void unload (Cancellable? cancellable) throws Error, IOError {
			if (unloading)
				throw new Error.INVALID_OPERATION ("Agent is already unloading");
			unloading = true;
			perform_unload.begin ();
		}

		private async void perform_unload () {
			Promise<bool> operation = null;

			AgentSessionProvider? emulated_provider;
			try {
				emulated_provider = yield try_get_emulated_provider (null);
			} catch (IOError e) {
				assert_not_reached ();
			}
			if (emulated_provider != null)
				emulated_provider.unload.begin (null);

			lock (pending_calls) {
				if (pending_calls > 0) {
					pending_close = new Promise<bool> ();
					operation = pending_close;
				}
			}

			if (operation != null) {
				try {
					yield operation.future.wait_async (null);
				} catch (GLib.Error e) {
					assert_not_reached ();
				}
			}

			yield close_all_clients ();

			yield teardown_connection ();

			if (stop_thread_on_unload) {
				schedule_idle (() => {
					main_loop.quit ();
					return false;
				});
			}
		}

		private void ensure_eternalized () {
			if (!_is_eternal) {
				_is_eternal = true;
				eternalized ();
			}
		}

		public void acquire_child_gating () {
			child_gating_subscriber_count++;
			if (child_gating_subscriber_count == 1)
				enable_child_gating ();
			child_gating_changed (child_gating_subscriber_count);
		}

		public void release_child_gating () {
			child_gating_subscriber_count--;
			if (child_gating_subscriber_count == 0)
				disable_child_gating ();
			child_gating_changed (child_gating_subscriber_count);
		}

		private void enable_child_gating () {
			if (spawn_monitor != null)
				return;

			var interceptor = Gum.Interceptor.obtain ();
			interceptor.begin_transaction ();

			fork_monitor = new ForkMonitor (this);
			fd_guard = new FileDescriptorGuard (agent_range);

			thread_list_cloaker = new ThreadListCloaker ();
			fd_list_cloaker = new FDListCloaker ();

			spawn_monitor = new SpawnMonitor (this, main_context);

			interceptor.end_transaction ();
		}

		private void disable_child_gating () {
			if (spawn_monitor == null)
				return;

			var interceptor = Gum.Interceptor.obtain ();
			interceptor.begin_transaction ();

			spawn_monitor = null;

			fd_list_cloaker = null;
			thread_list_cloaker = null;

			fd_guard = null;
			fork_monitor = null;

			interceptor.end_transaction ();
		}

		public void schedule_idle (owned SourceFunc function) {
			var source = new IdleSource ();
			source.set_callback ((owned) function);
			source.attach (main_context);
		}

		public void schedule_timeout (uint delay, owned SourceFunc function) {
			var source = new TimeoutSource (delay);
			source.set_callback ((owned) function);
			source.attach (main_context);
		}

		private async void setup_connection_with_transport_uri (string transport_uri) {
			IOStream stream;
			try {
				if (transport_uri.has_prefix ("socket:")) {
					var socket = new Socket.from_fd (int.parse (transport_uri[7:]));
					stream = SocketConnection.factory_create_connection (socket);
				} else if (transport_uri.has_prefix ("pipe:")) {
					stream = yield Pipe.open (transport_uri, null).wait_async (null);
				} else {
					error ("Invalid transport URI: %s", transport_uri);
				}
			} catch (GLib.Error e) {
				assert_not_reached ();
			}

			yield setup_connection_with_stream (stream);
		}

		private async void setup_connection_with_stream (IOStream stream) {
			try {
				connection = yield new DBusConnection (stream, null, AUTHENTICATION_CLIENT | DELAY_MESSAGE_PROCESSING);
			} catch (GLib.Error connection_error) {
				printerr ("Unable to create connection: %s\n", connection_error.message);
				return;
			}

			connection.on_closed.connect (on_connection_closed);
			filter_id = connection.add_filter (on_connection_message);

			try {
				AgentSessionProvider provider = this;
				registration_id = connection.register_object (ObjectPath.AGENT_SESSION_PROVIDER, provider);

				connection.start_message_processing ();
			} catch (IOError io_error) {
				assert_not_reached ();
			}

			try {
				controller = yield connection.get_proxy (null, ObjectPath.AGENT_CONTROLLER, DBusProxyFlags.NONE, null);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}
		}

		private async void teardown_connection () {
			if (connection == null)
				return;

			connection.on_closed.disconnect (on_connection_closed);

			try {
				yield connection.flush ();
			} catch (GLib.Error e) {
			}

			try {
				yield connection.close ();
			} catch (GLib.Error e) {
			}

			unregister_connection ();

			connection = null;
		}

		private void discard_connections () {
			foreach (var dc in direct_connections.values.to_array ()) {
				detach_and_steal_direct_dbus_connection (dc.connection);

				dc.connection.dispose ();
			}

			if (connection == null)
				return;

			connection.on_closed.disconnect (on_connection_closed);

			unregister_connection ();

			connection.dispose ();
			connection = null;
		}

		private void unregister_connection () {
			foreach (var id in emulated_session_registrations.values)
				connection.unregister_object (id);
			emulated_session_registrations.clear ();

			foreach (var client in clients.values) {
				var id = client.registration_id;
				if (id != 0)
					connection.unregister_object (id);
				client.registration_id = 0;
			}

			controller = null;

			if (registration_id != 0) {
				connection.unregister_object (registration_id);
				registration_id = 0;
			}

			if (filter_id != 0) {
				connection.remove_filter (filter_id);
				filter_id = 0;
			}
		}

		private void on_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			bool closed_by_us = (!remote_peer_vanished && error == null);
			if (!closed_by_us)
				unload.begin (null);

			Promise<bool> operation = null;
			lock (pending_calls) {
				pending_calls = 0;
				operation = pending_close;
				pending_close = null;
			}
			if (operation != null)
				operation.resolve (true);
		}

		private GLib.DBusMessage on_connection_message (DBusConnection connection, owned DBusMessage message, bool incoming) {
			switch (message.get_message_type ()) {
				case DBusMessageType.METHOD_CALL:
					if (incoming) {
						lock (pending_calls) {
							pending_calls++;
						}
					}
					break;
				case DBusMessageType.METHOD_RETURN:
				case DBusMessageType.ERROR:
					if (!incoming) {
						lock (pending_calls) {
							pending_calls--;
							var operation = pending_close;
							if (pending_calls == 0 && operation != null) {
								pending_close = null;
								schedule_idle (() => {
									operation.resolve (true);
									return false;
								});
							}
						}
					}
					break;
				default:
					break;
			}

			return message;
		}

		private async void prepare_for_termination (TerminationReason reason) {
			foreach (var client in clients.values.to_array ())
				yield client.prepare_for_termination (reason);

			var connection = this.connection;
			if (connection != null) {
				try {
					yield connection.flush ();
				} catch (GLib.Error e) {
				}
			}
		}

		private void unprepare_for_termination () {
			foreach (var client in clients.values.to_array ())
				client.unprepare_for_termination ();
		}

#if ANDROID && X86
		private const string LIBNATIVEBRIDGE_PATH = "/system/lib/libnativebridge.so";
		private const int RTLD_LAZY = 1;

		private Promise<AgentSessionProvider>? get_emulated_request;
		private void * emulated_agent;
		private NBOnLoadFunc? emulated_entrypoint;
		private Socket? emulated_socket;
		private Thread<bool>? emulated_worker;

		private async AgentSessionProvider? try_get_emulated_provider (Cancellable? cancellable) throws IOError {
			if (get_emulated_request == null)
				return null;

			try {
				return yield get_emulated_provider (cancellable);
			} catch (Error e) {
				return null;
			}
		}

		private async AgentSessionProvider get_emulated_provider (Cancellable? cancellable) throws Error, IOError {
			while (get_emulated_request != null) {
				try {
					return yield get_emulated_request.future.wait_async (cancellable);
				} catch (Error e) {
					throw e;
				} catch (IOError e) {
					assert (e is IOError.CANCELLED);
					cancellable.set_error_if_cancelled ();
				}
			}
			get_emulated_request = new Promise<AgentSessionProvider> ();

			try {
				if (emulated_entrypoint == null) {
					string parent_path = Path.get_dirname (agent_path);

					string emulated_agent_path = Path.build_filename (parent_path, "frida-agent-arm.so");
					if (!FileUtils.test (emulated_agent_path, EXISTS)) {
						throw new Error.NOT_SUPPORTED (
							"Unable to handle emulated processes due to build configuration");
					}

					var load_library = (NBLoadLibraryFunc) Gum.Module.find_export_by_name (LIBNATIVEBRIDGE_PATH,
						"_ZN7android23NativeBridgeLoadLibraryEPKci");
					var get_trampoline = (NBGetTrampolineFunc) Gum.Module.find_export_by_name (LIBNATIVEBRIDGE_PATH,
						"_ZN7android25NativeBridgeGetTrampolineEPvPKcS2_j");
					if (load_library == null || get_trampoline == null)
						throw new Error.NOT_SUPPORTED ("NativeBridge interface is not available on this OS");

					emulated_agent = load_library (emulated_agent_path, RTLD_LAZY);
					if (emulated_agent == null)
						throw new Error.NOT_SUPPORTED ("Process is not using emulation");

					emulated_entrypoint = (NBOnLoadFunc) get_trampoline (emulated_agent, "frida_agent_main_nb");
				}

				var fds = new int[2];
				if (Posix.socketpair (Posix.AF_UNIX, Posix.SOCK_STREAM, 0, fds) != 0)
					throw new Error.NOT_SUPPORTED ("Unable to allocate socketpair");

				Socket local_socket, remote_socket;
				try {
					local_socket = new Socket.from_fd (fds[0]);
					remote_socket = new Socket.from_fd (fds[1]);
				} catch (GLib.Error e) {
					assert_not_reached ();
				}

				IOStream stream = SocketConnection.factory_create_connection (local_socket);
				emulated_socket = remote_socket;

				emulated_worker = new Thread<bool> ("frida-agent-emulated", run_emulated_agent);

				var connection = yield new DBusConnection (stream, ServerGuid.HOST_SESSION_SERVICE,
					AUTHENTICATION_SERVER | AUTHENTICATION_ALLOW_ANONYMOUS, null, cancellable);

				AgentSessionProvider provider = yield connection.get_proxy (null, ObjectPath.AGENT_SESSION_PROVIDER,
					DBusProxyFlags.NONE, cancellable);

				provider.opened.connect (on_emulated_session_opened);
				provider.closed.connect (on_emulated_session_closed);
				provider.child_gating_changed.connect (on_emulated_child_gating_changed);

				ensure_eternalized ();

				get_emulated_request.resolve (provider);
				return provider;
			} catch (GLib.Error raw_error) {
				DBusError.strip_remote_error (raw_error);

				if (emulated_worker != null) {
					emulated_worker.join ();
					emulated_worker = null;
				}

				emulated_socket = null;

				GLib.Error e;
				if (raw_error is Error || raw_error is IOError.CANCELLED)
					e = raw_error;
				else
					e = new Error.TRANSPORT ("%s", raw_error.message);

				get_emulated_request.reject (e);
				get_emulated_request = null;

				throw_api_error (e);
			}
		}

		private bool run_emulated_agent () {
			var fake_vm = new FakeJavaVM ();
			var invocation = EmulatedInvocation (emulated_socket.fd);

			emulated_entrypoint (&fake_vm, &invocation);

			return true;
		}

		private void on_emulated_session_opened (AgentSessionId id) {
			opened (id);
		}

		private void on_emulated_session_closed (AgentSessionId id) {
			uint registration_id;
			if (emulated_session_registrations.unset (id, out registration_id))
				connection.unregister_object (registration_id);

			closed (id);
		}

		private void on_emulated_child_gating_changed (uint subscriber_count) {
			// TODO: Wire up remainder of the child gating logic.
			child_gating_changed (subscriber_count);
		}

		[CCode (has_target = false)]
		private delegate void * NBLoadLibraryFunc (string path, int flags);

		[CCode (has_target = false)]
		private delegate void * NBGetTrampolineFunc (void * handle, string name, string? shorty = null, uint32 len = 0);

		[CCode (has_target = false)]
		private delegate int NBOnLoadFunc (void * vm, void * reserved);

#else
		private async AgentSessionProvider? try_get_emulated_provider (Cancellable? cancellable) throws IOError {
			return null;
		}

		private async AgentSessionProvider get_emulated_provider (Cancellable? cancellable) throws Error, IOError {
			throw new Error.NOT_SUPPORTED ("Emulated realm is not supported on this OS");
		}
#endif
	}

#if ANDROID
	public struct EmulatedInvocation {
		public string agent_parameters;
		public UnloadPolicy unload_policy;
		public LinuxInjectorState * injector_state;

		public EmulatedInvocation (int fd) {
			agent_parameters = "socket:%d|eternal|sticky".printf (fd);
			unload_policy = IMMEDIATE;
		}
	}

	[Compact]
	public class FakeJavaVM {
		public FakeJNIInvokeInterface functions;

		public FakeJavaVM () {
			functions = new FakeJNIInvokeInterface ();
		}
	}

	[Compact]
	public class FakeJNIInvokeInterface {
		public void * reserved0;
		public void * reserved1;
		public void * reserved2;

		public void * destroy_java_vm;
		public void * attach_current_thread;
		public void * detach_current_thread;
		public void * get_env;
		public void * attach_current_thread_as_daemon;

		public FakeJNIInvokeInterface () {
			void * stub = (void *) Process.abort;
			destroy_java_vm = stub;
			attach_current_thread = stub;
			detach_current_thread = stub;
			get_env = stub;
			attach_current_thread_as_daemon = stub;
		}
	}
#endif

	private class AgentClient : Object, AgentSession {
		public signal void closed ();
		public signal void script_eternalized (Gum.Script script);

		public weak Runner runner {
			get;
			construct;
		}

		public AgentSessionId id {
			get;
			construct;
		}

		public uint registration_id {
			get;
			set;
		}

		private Promise<bool> close_request;
		private Promise<bool> flush_complete = new Promise<bool> ();

		private bool child_gating_enabled = false;
		private ScriptEngine script_engine;

		public AgentClient (Runner runner, AgentSessionId id) {
			Object (runner: runner, id: id);
		}

		construct {
			script_engine = new ScriptEngine (runner);
			script_engine.message_from_script.connect (on_message_from_script);
			script_engine.message_from_debugger.connect (on_message_from_debugger);
		}

		public async void close (Cancellable? cancellable) throws Error, IOError {
			while (close_request != null) {
				try {
					yield close_request.future.wait_async (cancellable);
					return;
				} catch (GLib.Error e) {
					assert (e is IOError.CANCELLED);
					cancellable.set_error_if_cancelled ();
				}
			}
			close_request = new Promise<bool> ();

			try {
				yield disable_child_gating (cancellable);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}

			yield script_engine.flush ();
			flush_complete.resolve (true);

			yield script_engine.close ();
			script_engine.message_from_script.disconnect (on_message_from_script);
			script_engine.message_from_debugger.disconnect (on_message_from_debugger);

			closed ();

			close_request.resolve (true);
		}

		public async void flush () {
			if (close_request == null)
				close.begin (null);

			try {
				yield flush_complete.future.wait_async (null);
			} catch (GLib.Error e) {
				assert_not_reached ();
			}
		}

		public async void prepare_for_termination (TerminationReason reason) {
			yield script_engine.prepare_for_termination (reason);
		}

		public void unprepare_for_termination () {
			script_engine.unprepare_for_termination ();
		}

		public async void enable_child_gating (Cancellable? cancellable) throws Error, IOError {
			check_open ();

			if (child_gating_enabled)
				return;

			runner.acquire_child_gating ();

			child_gating_enabled = true;
		}

		public async void disable_child_gating (Cancellable? cancellable) throws Error, IOError {
			if (!child_gating_enabled)
				return;

			runner.release_child_gating ();

			child_gating_enabled = false;
		}

		public async AgentScriptId create_script (string name, string source, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var options = new ScriptOptions ();
			if (name != "")
				options.name = name;

			var instance = yield script_engine.create_script (source, null, options);
			return instance.script_id;
		}

		public async AgentScriptId create_script_with_options (string source, AgentScriptOptions options,
				Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var instance = yield script_engine.create_script (source, null, ScriptOptions._deserialize (options.data));
			return instance.script_id;
		}

		public async AgentScriptId create_script_from_bytes (uint8[] bytes, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var instance = yield script_engine.create_script (null, new Bytes (bytes), new ScriptOptions ());
			return instance.script_id;
		}

		public async AgentScriptId create_script_from_bytes_with_options (uint8[] bytes, AgentScriptOptions options,
				Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var instance = yield script_engine.create_script (null, new Bytes (bytes),
				ScriptOptions._deserialize (options.data));
			return instance.script_id;
		}

		public async uint8[] compile_script (string name, string source, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var options = new ScriptOptions ();
			if (name != "")
				options.name = name;

			var bytes = yield script_engine.compile_script (source, options);
			return bytes.get_data ();
		}

		public async uint8[] compile_script_with_options (string source, AgentScriptOptions options,
				Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var bytes = yield script_engine.compile_script (source, ScriptOptions._deserialize (options.data));
			return bytes.get_data ();
		}

		public async void destroy_script (AgentScriptId script_id, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			yield script_engine.destroy_script (script_id);
		}

		public async void load_script (AgentScriptId script_id, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			yield script_engine.load_script (script_id);
		}

		public async void eternalize_script (AgentScriptId script_id, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			var script = script_engine.eternalize_script (script_id);
			script_eternalized (script);
		}

		public async void post_to_script (AgentScriptId script_id, string message, bool has_data, uint8[] data,
				Cancellable? cancellable) throws Error, IOError {
			check_open ();

			script_engine.post_to_script (script_id, message, has_data ? new Bytes (data) : null);
		}

		public async void enable_debugger (Cancellable? cancellable) throws Error, IOError {
			check_open ();

			script_engine.enable_debugger ();
		}

		public async void disable_debugger (Cancellable? cancellable) throws Error, IOError {
			check_open ();

			script_engine.disable_debugger ();
		}

		public async void post_message_to_debugger (string message, Cancellable? cancellable) throws Error, IOError {
			check_open ();

			script_engine.post_message_to_debugger (message);
		}

		public async void enable_jit (Cancellable? cancellable) throws Error, IOError {
			check_open ();

			script_engine.enable_jit ();
		}

		private void check_open () throws Error {
			if (close_request != null)
				throw new Error.INVALID_OPERATION ("Session is closing");
		}

		private void on_message_from_script (AgentScriptId script_id, string message, Bytes? data) {
			bool has_data = data != null;
			var data_param = has_data ? data.get_data () : new uint8[0];
			this.message_from_script (script_id, message, has_data, data_param);
		}

		private void on_message_from_debugger (string message) {
			this.message_from_debugger (message);
		}
	}

	private class DirectConnection {
		public AgentClient client;

		public DBusConnection connection;
		public uint registration_id;

		public DirectConnection (AgentClient client) {
			this.client = client;
		}
	}

	namespace Environment {
		public extern void _init ();
		public extern void _deinit ();
	}

	private Mutex gc_mutex;
	private uint gc_generation = 0;
	private bool gc_scheduled = false;

	public void _on_pending_thread_garbage (void * data) {
		gc_mutex.lock ();
		gc_generation++;
		bool already_scheduled = gc_scheduled;
		gc_scheduled = true;
		gc_mutex.unlock ();

		if (already_scheduled)
			return;

		Runner.shared_mutex.lock ();
		var runner = Runner.shared_instance;
		Runner.shared_mutex.unlock ();

		if (runner == null)
			return;

		runner.schedule_timeout (50, () => {
			gc_mutex.lock ();
			uint generation = gc_generation;
			gc_mutex.unlock ();

			bool collected_everything = Thread.garbage_collect ();

			gc_mutex.lock ();
			bool same_generation = generation == gc_generation;
			bool repeat = !collected_everything || !same_generation;
			if (!repeat)
				gc_scheduled = false;
			gc_mutex.unlock ();

			return repeat;
		});
	}
}
