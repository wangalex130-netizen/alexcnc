# RKNN conversion: fire/smoke YOLOv8n@416 (v7) -> RK3566 INT8
from rknn.api import RKNN
import sys

def main():
    rknn = RKNN(verbose=False)
    print('-- config')
    ret = rknn.config(
        mean_values=[[0, 0, 0]],
        std_values=[[255, 255, 255]],
        target_platform='rk3566',
        quantized_dtype='w8a16',
        quantized_algorithm='normal',
        quantized_method='channel',
        optimization_level=3,
    )
    assert ret == 0, 'config failed'
    print('-- load onnx')
    ret = rknn.load_onnx(model='v7_ep17_best.onnx')
    assert ret == 0, 'load_onnx failed'
    print('-- build (INT8 quantization, 35 calib images)')
    ret = rknn.build(do_quantization=True, dataset='calib_list.txt')
    assert ret == 0, 'build failed'
    print('-- export')
    ret = rknn.export_rknn('v7_fire_smoke_416_int8.rknn')
    assert ret == 0, 'export failed'
    print('-- RKNN EXPORT DONE')
    rknn.release()

if __name__ == '__main__':
    sys.exit(main())
