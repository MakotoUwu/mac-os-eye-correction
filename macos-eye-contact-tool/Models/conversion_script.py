import tensorflow as tf
import coremltools as ct
import os

def convert_tf_checkpoint_to_coreml(checkpoint_dir, meta_filename, 
                                    output_mlmodel_path,
                                    input_tensor_map_shapes, # dict: {'name:port': (B,H,W,C)}
                                    output_tensor_names,     # list: ['name:port']
                                    phase_train_tensor_name='model_control/phase_train:0'):
    """
    Converts a TensorFlow 1.x checkpoint model to a Core ML model.

    Args:
        checkpoint_dir (str): Directory containing checkpoint files and meta graph.
        meta_filename (str): Name of the .meta graph file.
        output_mlmodel_path (str): Path to save the converted .mlmodel file.
        input_tensor_map_shapes (dict): Dictionary mapping input tensor names 
                                         (e.g., 'inputs/input_img:0') to their
                                         full shapes including batch size (e.g., (1, 48, 64, 3)).
        output_tensor_names (list): List of output tensor names (e.g., 'tower_0/warping_model/Tanh:0').
        phase_train_tensor_name (str, optional): Name of the phase_train boolean placeholder.
                                                 Defaults to 'model_control/phase_train:0'.
    """
    tf.compat.v1.disable_eager_execution() # Important for TF1.x graph manipulation
    
    graph = tf.Graph()
    with graph.as_default():
        with tf.compat.v1.Session(graph=graph) as sess:
            # 1. Prepare to map phase_train to False
            # Create a constant False tensor
            phase_train_const = tf.constant(False, dtype=tf.bool, name='phase_train_const_val')
            
            # 2. Load the meta graph, clearing devices and mapping phase_train
            # The input_map will effectively replace phase_train_tensor_name with phase_train_const
            print(f"Loading meta graph: {os.path.join(checkpoint_dir, meta_filename)}")
            saver = tf.compat.v1.train.import_meta_graph(
                os.path.join(checkpoint_dir, meta_filename),
                clear_devices=True,
                input_map={phase_train_tensor_name: phase_train_const}
            )
            
            # 3. Restore weights
            latest_ckpt = tf.train.latest_checkpoint(checkpoint_dir)
            if not latest_ckpt:
                raise ValueError(f"No checkpoint found in directory: {checkpoint_dir}")
            print(f"Restoring weights from: {latest_ckpt}")
            saver.restore(sess, latest_ckpt)
            print("Weights restored successfully.")

            # 4. Freeze the graph
            # Output node names for freezing should not include ':port'
            output_node_names_for_freezing = [name.split(':')[0] for name in output_tensor_names]
            
            print(f"Freezing graph with output nodes: {output_node_names_for_freezing}")
            frozen_graph_def = tf.compat.v1.graph_util.convert_variables_to_constants(
                sess,
                sess.graph_def, # Use the graph_def from the current session
                output_node_names_for_freezing
            )
            
            # Save frozen graph for inspection (optional) and conversion
            frozen_pb_path = os.path.join(checkpoint_dir, "frozen_model.pb")
            with tf.io.gfile.GFile(frozen_pb_path, "wb") as f:
                f.write(frozen_graph_def.SerializeToString())
            print(f"Frozen graph saved to: {frozen_pb_path}")

            # 5. Convert the frozen graph to Core ML
            print("Converting to Core ML...")
            
            # Define Core ML input types based on the provided map
            # Exclude phase_train if it was successfully mapped to a constant
            coreml_inputs = []
            for name_with_port, shape in input_tensor_map_shapes.items():
                if name_with_port == phase_train_tensor_name: # Should have been replaced by constant
                    continue 
                # Batch size is typically 1 for inference. Shape already includes it.
                actual_input_name_for_coreml = name_with_port.split(':')[0]
                coreml_inputs.append(ct.TensorType(name=actual_input_name_for_coreml, shape=shape)) 

            mlmodel = ct.convert(
                frozen_graph_def, # model argument - pass the GraphDef directly
                source='tensorflow',
                outputs=[ct.TensorType(name=name) for name in output_tensor_names], # Must be TensorType for outputs too
                inputs=coreml_inputs,
                minimum_deployment_target=ct.target.macOS12 # Or iOS if needed
            )
            
            # 6. Save the Core ML model
            mlmodel.save(output_mlmodel_path)
            print(f"Core ML model saved to: {output_mlmodel_path}")
            print("\nConversion Complete!")
            print("Input details for Core ML model:")
            for spec_input in mlmodel.get_spec().description.input:
                print(f"  Name: {spec_input.name}, Type: {spec_input.type}")
            print("Output details for Core ML model:")
            for spec_output in mlmodel.get_spec().description.output:
                 print(f"  Name: {spec_output.name}, Type: {spec_output.type}")


if __name__ == '__main__':
    # --- CONFIGURATION FOR RIGHT EYE MODEL ---
    MODEL_DIR = 'OriginalModel/R' # Changed from L to R
    META_FILE = 'R.meta'          # Changed from L.meta to R.meta
    OUTPUT_MLMODEL_R = 'RightEyeWarp.mlpackage' # New output file name for Right eye

    # (Batch, Height, Width, Channels) or (Batch, Features)
    # Batch size is 1 for typical inference.
    # These tensor names and shapes are assumed to be the same for the Right eye model
    input_tensor_map_shapes = {
        'inputs/input_img:0': (1, 48, 64, 3),  # (batch, height, width, channels)
        'inputs/input_fp:0': (1, 48, 64, 12), # (batch, height, width, feature_channels)
        'inputs/input_ang:0': (1, 2),          # (batch, num_angles)
        'model_control/phase_train:0': None    # Placeholder for boolean, actual shape not critical
                                               # as it's mapped to a constant
    }
    output_tensor_name = 'tower_0/warping_model/Tanh:0' # (batch, height, width, 2) for warp field

    # The checkpoint directory is the same as MODEL_DIR for these models
    checkpoint_dir = MODEL_DIR 

    # Construct the full path for the output Core ML model
    output_mlmodel_full_path = os.path.join(MODEL_DIR, OUTPUT_MLMODEL_R)

    print(f"Starting conversion for Right Eye model:")
    print(f"  Model Directory: {MODEL_DIR}")
    print(f"  Meta File: {META_FILE}")
    print(f"  Checkpoint Directory: {checkpoint_dir}")
    print(f"  Output Core ML Model: {output_mlmodel_full_path}")

    convert_tf_checkpoint_to_coreml(
        checkpoint_dir=checkpoint_dir,
        meta_filename=META_FILE,
        output_mlmodel_path=output_mlmodel_full_path,
        input_tensor_map_shapes=input_tensor_map_shapes,
        output_tensor_names=[output_tensor_name],
        phase_train_tensor_name='model_control/phase_train:0'
    )