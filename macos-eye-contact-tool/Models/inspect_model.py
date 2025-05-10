import tensorflow as tf
import os

def inspect_checkpoint_model(checkpoint_dir, meta_graph_filename):
    graph = tf.Graph()
    with graph.as_default():
        # Start a session
        with tf.compat.v1.Session(graph=graph) as sess:
            # Load the meta graph
            saver = tf.compat.v1.train.import_meta_graph(os.path.join(checkpoint_dir, meta_graph_filename), clear_devices=True)
            
            # Restore weights - tf.train.latest_checkpoint will find the 'checkpoint' file
            # and use it to determine which checkpoint to load.
            latest_ckpt = tf.train.latest_checkpoint(checkpoint_dir)
            if latest_ckpt:
                print(f"Restoring weights from: {latest_ckpt}")
                saver.restore(sess, latest_ckpt)
                print("Weights restored successfully.")
            else:
                print(f"Error: No checkpoint found in directory: {checkpoint_dir}")
                return

            # Print all operation names and tensor details
            print("\nAll operations and tensors in the graph:")
            for op in graph.get_operations():
                print(f"- Operation Name: {op.name} (Type: {op.type})")
                # print(f"  Device: {op.device}") # Optional: shows device placement
                # print(f"  Inputs to Op: {[inp.name for inp in op.inputs]}") # Tensors that are inputs to this op
                
                # Print details of output tensors from this operation
                if len(op.outputs) > 0:
                    print(f"  Output Tensors from Op '{op.name}':")
                    for i, tensor in enumerate(op.outputs):
                        print(f"    - Tensor Name: {tensor.name} (Shape: {tensor.shape}, DType: {tensor.dtype.name})")
                        # Note: tensor.name is usually op.name + ':0', op.name + ':1', etc.
            
            print("\n--- Inputs (Placeholders) ---")
            # Try to find placeholders which are often inputs
            placeholders = [op for op in graph.get_operations() if op.type == 'Placeholder']
            if placeholders:
                for ph_op in placeholders:
                    print(f"Potential Input (Placeholder Op): {ph_op.name}")
                    for tensor in ph_op.outputs: # Placeholders have outputs which are the tensors themselves
                         print(f"  Tensor Name: {tensor.name}, Shape: {tensor.shape}, DType: {tensor.dtype.name}")
            else:
                print("No explicit Placeholder ops found. Inputs might be defined differently.")

            print("\n--- Hints for finding I/O Tensors ---")
            print("Look for tensor names related to:")
            print("  Inputs: 'im_ph', 'alpha_ph', 'beta_ph', 'input_image', 'angles', 'phase_train', or similar.")
            print("          Input shapes might match (None, 48, 64, 3) for image, (None, 1) for angles based on original config.py.")
            print("  Outputs: 'warp_field', 'displacement_map', 'output', 'prediction', or similar.")
            print("           Output shape could be something like (None, 48, 64, 2) for a 2D warp field.")

if __name__ == '__main__':
    # Relative to the Models/ directory where this script is located
    checkpoint_base_dir = 'OriginalModel/L' 
    meta_file = 'L.meta'

    if not os.path.exists(os.path.join(checkpoint_base_dir, meta_file)):
        print(f"Error: Meta graph file not found at {os.path.join(checkpoint_base_dir, meta_file)}")
    else:
        try:
            inspect_checkpoint_model(checkpoint_base_dir, meta_file)
        except Exception as e:
            print(f"An error occurred during model inspection: {e}")
            import traceback
            traceback.print_exc()
