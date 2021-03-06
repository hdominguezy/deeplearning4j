/*******************************************************************************
 * Copyright (c) 2015-2018 Skymind, Inc.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

#include "../NativeOpExecutioner.h"
#include <cuda.h>
#include <op_boilerplate.h>
#include <helpers/DebugHelper.h>
#include <DataTypeUtils.h>
#include <exceptions/datatype_exception.h>
#include <helpers/CudaLaunchHelper.h>
#include <helpers/ShapeBuilders.h>
#include <PointersManager.h>

#include <array/ConstantDataBuffer.h>
#include <array/ShapeDescriptor.h>
#include <helpers/ConstantShapeHelper.h>

#include <loops/transform_float.h>
#include <loops/transform_bool.h>
#include <loops/transform_any.h>
#include <loops/transform_same.h>
#include <loops/transform_strict.h>
#include <loops/reduce_float.h>
#include <loops/reduce_same.h>
#include <loops/reduce_bool.h>
#include <loops/reduce_long.h>
#include <loops/broadcasting.h>
#include <loops/indexreduce.h>
#include <loops/pairwise_transform.h>
#include <loops/pairwise_bool.h>
#include <loops/broadcasting_bool.h>
#include <loops/reduce_float.h>
#include <loops/reduce3.h>
#include <loops/summarystatsreduce.h>
#include <loops/transform_same.h>
#include <loops/scalar.h>
#include <loops/random.h>
#include <loops/special_kernels.h>
#include <loops/scalar_bool.h>

using namespace nd4j;

/**
* This is utility kernel, that updates given special buffer with proper values in device memory
*/
extern "C" __global__ void prepareShapeBuffer(int *dimension, int *maxDimension, Nd4jLong *specialPointer, int rows, nd4j::DataType dataType) {
    Nd4jLong tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid > 0)
        return;

    dimension[0] = 0;
    maxDimension[0] = 1;

    specialPointer[0] = 2;
    specialPointer[1] = rows;
    specialPointer[2] = 1;
    specialPointer[3] = 1;
    specialPointer[4] = 1;
    specialPointer[5] = 0;
    specialPointer[6] = 1;
    specialPointer[7] = 99;

    ArrayOptions::setDataType(specialPointer, dataType);

    //printf("special[0]: [%lld]\n", (long long) specialPointer[0]);
    //shape::printShapeInfoLinear("prepareShapeBuffer", specialPointer);
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execPairwiseTransform(nd4j::LaunchContext  *lc,
                                    int opNum,
                                    void *hX, Nd4jLong *hXShapeInfo,
                                    void *dX, Nd4jLong *dXShapeInfo,
                                    void *hY, Nd4jLong *hYShapeInfo,
                                    void *dY, Nd4jLong *dYShapeInfo,
                                    void *hZ, Nd4jLong *hZShapeInfo,
                                    void *dZ, Nd4jLong *dZShapeInfo,
                                    void *extraParams) {

    auto stream = lc->getCudaStream();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (xType != zType && yType != zType)
        throw std::runtime_error("NativeOpExecutioner::execPairwiseTransform requires Z operand to have either X or Y type");
    if (lc == nullptr)
        throw std::runtime_error("NativeOpExecutioner::execPairwiseTransform: launch context cannot be nullptr !");
    if (stream == nullptr)
        throw std::runtime_error("NativeOpExecutioner::execPairwiseTransform: CUDA stream cannot be nullptr !");

    dim3 launchDims(256, 1024, 8192);

#ifdef __ND4J_EXPERIMENTAL__
    BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::pairwise_transforms::PairWiseTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams), LIBND4J_TYPES, LIBND4J_TYPES)
#else
    BUILD_SINGLE_SELECTOR_THRICE(xType, functions::pairwise_transforms::PairWiseTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams), LIBND4J_TYPES)
#endif

    DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execPairwiseBoolTransform( nd4j::LaunchContext  *lc,
                                                    int opNum,
                                                    void *hX, Nd4jLong *hXShapeInfo,
                                                    void *dX, Nd4jLong *dXShapeInfo,
                                                    void *hY, Nd4jLong *hYShapeInfo,
                                                    void *dY, Nd4jLong *dYShapeInfo,
                                                    void *hZ, Nd4jLong *hZShapeInfo,
                                                    void *dZ, Nd4jLong *dZShapeInfo,
                                                    void *extraParams) {

	auto stream = lc->getCudaStream();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isB(zType))
		throw nd4j::datatype_exception::build("NativeOpExecutioner::execPairwiseBoolTransform wrong Z operand data type", nd4j::DataType::BOOL, zType);

    if (yType != xType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execPairwiseBoolTransform both operands must have same data type", xType, yType);

    dim3 launchDims(256, 1024, 16384);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::pairwise_transforms::PairWiseBoolTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraParams), LIBND4J_TYPES, BOOL_TYPES)
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStatsScalar(nd4j::LaunchContext  *lc,
                                    int opNum,
                                    void *hX, Nd4jLong *hXShapeInfo,
                                    void *dX, Nd4jLong *dXShapeInfo,
                                    void *extraParams,
                                    void *hZ, Nd4jLong *hZShapeInfo,
                                    void *dZ, Nd4jLong *dZShapeInfo,
                                    bool biasCorrected) {

	auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    dim3 launchDims = dim3(256, 256, 32768);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::summarystats::SummaryStatsReduce, ::execSummaryStatsReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ, dZShapeInfo, hZShapeInfo, nullptr, nullptr, biasCorrected, reductionPointer), LIBND4J_TYPES, FLOAT_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execBroadcastBool(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *hY, Nd4jLong *hYShapeInfo,
                            void *dY, Nd4jLong *dYShapeInfo,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo,
                            int *dimension, int dimensionLength,
                            Nd4jLong *tadOnlyShapeInfo, Nd4jLong *tadOffsets,
                            Nd4jLong *tadOnlyShapeInfoZ,Nd4jLong *tadOffsetsZ) {

	auto stream = lc->getCudaStream();

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

	if (!DataTypeUtils::isB(zType))
        throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires Z operand to have BOOL type");

    if (yType != xType)
        throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires both X & Y operands to have same type");

	if (nd4j::Environment::getInstance()->isDebugAndVerbose())
		printf("F3B opNum:[%i]\n", opNum);

	dim3 launchDims(256, 256, 1024);

	BUILD_DOUBLE_SELECTOR(xType, zType, functions::broadcast::BroadcastBool, ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, BOOL_TYPES)

	DEBUG_KERNEL(stream, opNum);
}

void NativeOpExecutioner::execInverseBroadcastBool(nd4j::LaunchContext  *lc,
                                                   int opNum,
                                                   void *hX, Nd4jLong *hXShapeInfo,
                                                   void *dX, Nd4jLong *dXShapeInfo,
                                                   void *hY, Nd4jLong *hYShapeInfo,
                                                   void *dY, Nd4jLong *dYShapeInfo,
                                                   void *hZ, Nd4jLong *hZShapeInfo,
                                                   void *dZ, Nd4jLong *dZShapeInfo,
                                                   int *dimension, int dimensionLength,
                                                   Nd4jLong *tadOnlyShapeInfo, Nd4jLong *tadOffsets,
                                                   Nd4jLong *tadOnlyShapeInfoZ,Nd4jLong *tadOffsetsZ) {
    auto stream = lc->getCudaStream();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isB(zType))
        throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires Z operand to have BOOL type");

    if (yType != xType)
        throw std::runtime_error("NativeOpExecutioner::execBroadcastBool requires both X & Y operands to have same type");

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("F3BI opNum:[%i]\n", opNum);

    dim3 launchDims(256, 256, 1024);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::broadcast::BroadcastBool, ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, BOOL_TYPES)

    DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param dY
 * @param dYShapeInfo
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
void NativeOpExecutioner::execBroadcast(nd4j::LaunchContext  *lc,
		                              int opNum,
		                              void *hX, Nd4jLong *hXShapeInfo,
		                              void *dX, Nd4jLong *dXShapeInfo,
		                              void *hY, Nd4jLong *hYShapeInfo,
		                              void *dY, Nd4jLong *dYShapeInfo,
		                              void *hZ, Nd4jLong *hZShapeInfo,
		                              void *dZ, Nd4jLong *dZShapeInfo,
		                              int *dimension, int dimensionLength,
		                              Nd4jLong *tadOnlyShapeInfo, Nd4jLong *tadOffsets,
		                              Nd4jLong *tadOnlyShapeInfoZ,Nd4jLong *tadOffsetsZ) {

	auto stream = lc->getCudaStream();

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

	if (nd4j::Environment::getInstance()->isDebugAndVerbose())
		printf("F3 opNum:[%i]\n", opNum);

	dim3 launchDims(256, 256, 1024);

#ifdef __ND4J_EXPERIMENTAL__
	BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::broadcast::Broadcast, ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, LIBND4J_TYPES);
#else
    BUILD_SINGLE_SELECTOR_THRICE(xType, functions::broadcast::Broadcast, ::execBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES);
#endif

	DEBUG_KERNEL(stream, opNum);
}

void NativeOpExecutioner::execInverseBroadcast(nd4j::LaunchContext  *lc,
                                               int opNum,
                                               void *hX, Nd4jLong *hXShapeInfo,
                                               void *dX, Nd4jLong *dXShapeInfo,
                                               void *hY, Nd4jLong *hYShapeInfo,
                                               void *dY, Nd4jLong *dYShapeInfo,
                                               void *hZ, Nd4jLong *hZShapeInfo,
                                               void *dZ, Nd4jLong *dZShapeInfo,
                                               int *dimension, int dimensionLength,
                                               Nd4jLong *tadOnlyShapeInfo, Nd4jLong *tadOffsets,
                                               Nd4jLong *tadOnlyShapeInfoZ,Nd4jLong *tadOffsetsZ) {

    auto stream = lc->getCudaStream();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("F3I opNum:[%i]\n", opNum);

    dim3 launchDims(256, 256, 1024);

#ifdef __ND4J_EXPERIMENTAL__
    BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::broadcast::Broadcast, ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, LIBND4J_TYPES);
#else
    BUILD_SINGLE_SELECTOR_THRICE(xType, functions::broadcast::Broadcast, ::execInverseBroadcast(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, dimension, dimensionLength, tadOnlyShapeInfo, tadOffsets, tadOnlyShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES);
#endif

    DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceSame(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *extraParams,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo,
                            int *dimension, int dimensionLength,
                            Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("SF7 opNum:[%i]\n", opNum);

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);
    auto xRank = shape::rank(hXShapeInfo);

    if (zType != xType)
        throw datatype_exception::build("NativeOpExecutioner::execReduceSame requires both X & Z operands to have same type", xType, zType);

    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 8192);

    BUILD_SINGLE_SELECTOR(xType, functions::reduce::ReduceSameFunction, ::execReduceXD(launchDims, stream, opNum, xRank, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, dimension, dimensionLength, reductionPointer, tadShapeInfo, tadOffsets), LIBND4J_TYPES);

    nd4j::DebugHelper::checkErrorCode(stream, "execReduceSame(...) failed");
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceLong(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *extraParams,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo,
                            int *dimension,int dimensionLength,
                            Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("LF7 opNum:[%i]\n", opNum);

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (zType != nd4j::DataType::INT64)
        throw datatype_exception::build("NativeOpExecutioner::execReduceLong wrong Z data type", nd4j::DataType::INT64, zType);

    auto xRank = shape::rank(hXShapeInfo);
    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceLongFunction, ::execReduceXD(launchDims, stream, opNum, xRank, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, dimension, dimensionLength, reductionPointer, tadShapeInfo, tadOffsets), LIBND4J_TYPES, LONG_TYPES);

    nd4j::DebugHelper::checkErrorCode(stream, "execReduceLong(...) failed");

}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceBool(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *extraParams,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo,
                            int *dimension, int dimensionLength,
                            Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("BF7 opNum:[%i]\n", opNum);

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (zType != nd4j::DataType::BOOL)
        throw std::runtime_error("NativeOpExecutioner::execReduceBool requires Z operand to have BOOL type");

    auto xRank = shape::rank(hXShapeInfo);
    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceBoolFunction, ::execReduceXD(launchDims, stream, opNum, xRank, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, dimension, dimensionLength, reductionPointer, tadShapeInfo, tadOffsets), LIBND4J_TYPES, BOOL_TYPES);

    nd4j::DebugHelper::checkErrorCode(stream, "execReduceBool(...) failed");
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 * @param dimension
 * @param dimensionLength
 */
void NativeOpExecutioner::execIndexReduce(nd4j::LaunchContext  *lc,
                                int opNum,
                                void *hX, Nd4jLong *hXShapeInfo,
                                void *dX, Nd4jLong *dXShapeInfo,
                                void *extraParams,
                                void *hZ, Nd4jLong *hZShapeInfo,
                                void *dZ, Nd4jLong *dZShapeInfo,
                                int *dimension, int dimensionLength,
                                Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();
	auto allocationPointer = lc->getAllocationPointer();

	if (nd4j::Environment::getInstance()->isDebugAndVerbose())
		printf("F2 opNum:[%i]\n", opNum);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);
	auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    if (zType != nd4j::DataType::INT64)
        throw datatype_exception::build("NativeOpExecutioner::execIndexReduce requires Z operand to have INT64 type", zType);

	auto dz = reinterpret_cast<Nd4jLong*>(dZ);

	BUILD_SINGLE_SELECTOR(xType, functions::indexreduce::IndexReduce,  ::executeIndexReduce(launchDims, stream, opNum, dX, dXShapeInfo, shape::rank(hXShapeInfo), extraParams, dz, dZShapeInfo, shape::rank(hZShapeInfo), dimension, dimensionLength, 1, allocationPointer, reductionPointer, tadShapeInfo, tadOffsets), LIBND4J_TYPES);
}

////////////////////////////////////////////////////////////////////////
/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 * @param dZ
 * @param dZShapeInfo
 */
void  NativeOpExecutioner::execReduceFloat(nd4j::LaunchContext  *lc,
										int opNum,
										void *hX, Nd4jLong *hXShapeInfo,
        								void *dX, Nd4jLong *dXShapeInfo,
        								void *extraParams,
        								void *hZ, Nd4jLong *hZShapeInfo,
										void *dZ, Nd4jLong *dZShapeInfo,
										int *dimension,int dimensionLength,
										Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();

	if (nd4j::Environment::getInstance()->isDebugAndVerbose())
		printf("F8 opNum:[%i]\n", opNum);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    auto xRank = shape::rank(hXShapeInfo);
    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceFloatFunction, ::execReduceXD(launchDims, stream, opNum, xRank, dX,dXShapeInfo, extraParams, dZ, dZShapeInfo, dimension, dimensionLength, reductionPointer, tadShapeInfo, tadOffsets), LIBND4J_TYPES, FLOAT_TYPES);
}


/**
 *
 * @param opNum
 * @param dX
 * @param dXShapeInfo
 * @param extraParams
 */
////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execIndexReduceScalar(nd4j::LaunchContext  *lc,
											int opNum,
											void *hX, Nd4jLong *hXShapeInfo,
        									void *dX, Nd4jLong *dXShapeInfo,
        									void *extraParams,
        									void *hZ, Nd4jLong *hZShapeInfo,
											void *dZ, Nd4jLong *dZShapeInfo){

	if (nd4j::Environment::getInstance()->isDebug())
		printf("F1 opNum:[%i]\n", opNum);

	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();
	auto allocationPointer = lc->getAllocationPointer();

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

	if (nd4j::Environment::getInstance()->isDebugAndVerbose() && launchDims.x == 1)
		printf("AF1 opNum:[%i]\n", opNum);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    // FIXME: we want Z to be one of integer types
	//if (!DataTypeUtils::isZ(zType))
	//    throw nd4j::datatype_exception("NativeOpExecutioner::execIndexReduceScalar requires Z operand to have one of integer types")
	if (zType != nd4j::DataType::INT64)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execIndexReduceScalar requires Z operand to have INT64 data type", zType);

    auto dz = reinterpret_cast<Nd4jLong*>(dZ);

    BUILD_SINGLE_SELECTOR(xType, functions::indexreduce::IndexReduce, ::executeIndexReduceScalar(launchDims, stream,
                                                                                                opNum,
                                                                                                dX, dXShapeInfo, shape::rank(hXShapeInfo),
                                                                                                extraParams,
                                                                                                dz, dZShapeInfo, 0,
                                                                                                nullptr, 0,
                                                                                                1,
                                                                                                allocationPointer, reductionPointer,
                                                                                                nullptr, nullptr), LIBND4J_TYPES);
    nd4j::DebugHelper::checkErrorCode(stream, "execIndexReduceScalar(...) failed");
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceFloatScalar(nd4j::LaunchContext  *lc,
                                                int opNum,
                                                void *hX, Nd4jLong *hXShapeInfo,
                                                void *dX, Nd4jLong *dXShapeInfo,
                                                void *extraParams,
                                                void *hZ, Nd4jLong *hZShapeInfo,
                                                void *dZ, Nd4jLong *dZShapeInfo) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceFloatFunction, ::execReduceScalar(launchDims, stream, opNum, dX,dXShapeInfo, extraParams, dZ,dZShapeInfo, nullptr, 0, reductionPointer, nullptr), LIBND4J_TYPES, FLOAT_TYPES);
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceBoolScalar(nd4j::LaunchContext  *lc,
                                        int opNum,
                                        void *hX, Nd4jLong *hXShapeInfo,
                                        void *dX, Nd4jLong *dXShapeInfo,
                                        void *extraParams,
                                        void *hZ, Nd4jLong *hZShapeInfo,
                                        void *dZ, Nd4jLong *dZShapeInfo) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (zType != nd4j::DataType::BOOL)
        throw std::runtime_error("NativeOpExecutioner::execReduceBoolScalar requires Z operand to have BOOL type");

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceBoolFunction, ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, nullptr, 0, reductionPointer, nullptr), LIBND4J_TYPES, BOOL_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceSameScalar(nd4j::LaunchContext  *lc,
                                        int opNum,
                                        void *hX, Nd4jLong *hXShapeInfo,
                                        void *dX, Nd4jLong *dXShapeInfo,
                                        void *extraParams,
                                        void *hZ, Nd4jLong *hZShapeInfo,
                                        void *dZ, Nd4jLong *dZShapeInfo) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (zType != xType)
        throw datatype_exception::build("NativeOpExecutioner::execReduceSameScalar requires both X & Z operands to have same type", xType, zType);

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_SINGLE_SELECTOR(xType, functions::reduce::ReduceSameFunction, ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, nullptr, 0, reductionPointer, nullptr), LIBND4J_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduceLongScalar(nd4j::LaunchContext  *lc,
                                    int opNum,
                                    void *hX, Nd4jLong *hXShapeInfo,
                                    void *dX, Nd4jLong *dXShapeInfo,
                                    void *extraParams,
                                    void *hZ, Nd4jLong *hZShapeInfo,
                                    void *dZ, Nd4jLong *dZShapeInfo) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (zType != nd4j::DataType::INT64)
        throw datatype_exception::build("NativeOpExecutioner::execReduceLongScalar wrong Z data type", nd4j::DataType::INT64, zType);

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce::ReduceLongFunction, ::execReduceScalar(launchDims, stream, opNum, dX, dXShapeInfo, extraParams, dZ, dZShapeInfo, nullptr, 0, reductionPointer, nullptr), LIBND4J_TYPES, LONG_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformSame(nd4j::LaunchContext  *lc,
									int opNum,
                                   	void *hX, Nd4jLong *hXShapeInfo,
                                   	void *dX, Nd4jLong *dXShapeInfo,
                                   	void *hZ, Nd4jLong *hZShapeInfo,
                                   	void *dZ, Nd4jLong *dZShapeInfo,
                                   	void *extraParams,
                                   	Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

    auto stream = lc->getCudaStream();
    dim3 launchDims(512, 512, 16384);

    auto xRank = shape::rank(hXShapeInfo);
	auto zRank = shape::rank(hZShapeInfo);
	auto xType = ArrayOptions::dataType(hXShapeInfo);
    auto zType = ArrayOptions::dataType(hZShapeInfo);

    if (xType != zType)
        throw std::runtime_error("NativeOpExecutioner::execTransformSame requires X & Z to have same type");

    BUILD_SINGLE_SELECTOR(xType, functions::transform::TransformSame, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr), LIBND4J_TYPES);

    nd4j::DebugHelper::checkErrorCode(stream, "execTransformSame(...) failed");
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformBool(nd4j::LaunchContext  *lc,
                                int opNum,
                                void *hX, Nd4jLong *hXShapeInfo,
                                void *dX, Nd4jLong *dXShapeInfo,
                                void *hZ, Nd4jLong *hZShapeInfo,
                                void *dZ, Nd4jLong *dZShapeInfo,
                                void *extraParams,
                                Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();
	dim3 launchDims(512, 512, 16384);

	auto xRank = shape::rank(hXShapeInfo);
	auto zRank = shape::rank(hZShapeInfo);
	auto xType = ArrayOptions::dataType(hXShapeInfo);
    auto zType = ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isB(zType))
        throw std::runtime_error("NativeOpExecutioner::execTransformBool requires Z to have same boolean type");

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformBool, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr), LIBND4J_TYPES, BOOL_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformAny(nd4j::LaunchContext  *lc,
                                		int opNum,
                                		void *hX, Nd4jLong *hXShapeInfo,
                                		void *dX, Nd4jLong *dXShapeInfo,
                                		void *hZ, Nd4jLong *hZShapeInfo,
                                		void *dZ, Nd4jLong *dZShapeInfo,
                                		void *extraParams,
                                		Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

	auto stream = lc->getCudaStream();

	auto xRank = shape::rank(hXShapeInfo);
	auto zRank = shape::rank(hZShapeInfo);
	auto xType = ArrayOptions::dataType(hXShapeInfo);
	auto zType = ArrayOptions::dataType(hZShapeInfo);

	switch (opNum) {
        case transform::IsMax: {
                bool scalarCheat = false;
                if (extraParams == nullptr) {
                    scalarCheat = true;
                }

                void* special = lc->getAllocationPointer();

                if (scalarCheat) {
                    auto scalarShape = nd4j::ConstantShapeHelper::getInstance()->bufferForShapeInfo(ShapeDescriptor::scalarDescriptor(nd4j::DataType::INT64)); //ShapeBuilders::createScalarShapeInfo(nd4j::DataType::INT64);
                    /**
                    * In case of vector-input for IsMax, it just turns into IndexReduce call + further filler call
                    */
                    execIndexReduceScalar(lc, indexreduce::IndexMax, nullptr, hXShapeInfo, dX, dXShapeInfo, extraParams, nullptr, scalarShape.primaryAsT<Nd4jLong>(), special, scalarShape.specialAsT<Nd4jLong>());
                    Nd4jLong maxIdx = -119;
                    nd4j::DebugHelper::checkErrorCode(stream, "IsMax: execIndexReduce(...) failed");

                    cudaMemcpyAsync(&maxIdx, special, sizeof(Nd4jLong), cudaMemcpyDeviceToHost, *stream);
                    nd4j::DebugHelper::checkErrorCode(stream, "IsMax: cudaMemcpyAsync(...) failed");
                    int targetIdx = 0;

                    if (shape::order(hXShapeInfo) == 'c' || shape::order(hXShapeInfo) == 'f' && maxIdx * shape::stride(hXShapeInfo)[shape::rank(hXShapeInfo) - 1] >= shape::length(hXShapeInfo))
                        targetIdx = maxIdx;
                    else
                        targetIdx = maxIdx * shape::stride(hXShapeInfo)[shape::rank(hXShapeInfo) - 1];

                    dim3 launchDims(1, 512, 1024);
                    BUILD_SINGLE_SELECTOR(zType, fillIsMaxGeneric, (launchDims, stream, dZ, shape::length(hZShapeInfo), targetIdx), LIBND4J_TYPES);

                    nd4j::DebugHelper::checkErrorCode(stream, "Legacy IsMax(...) failed");

                    //delete[] scalarShape;
                }
            }
            break;
        default: {
            dim3 launchDims(512, 512, 16384);

            BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformAny, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr), LIBND4J_TYPES, LIBND4J_TYPES);
        }
	}
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformStrict(nd4j::LaunchContext  *lc,
                                    int opNum,
                                    void *hX, Nd4jLong *hXShapeInfo,
                                    void *dX, Nd4jLong *dXShapeInfo,
                                    void *hZ, Nd4jLong *hZShapeInfo,
                                    void *dZ, Nd4jLong *dZShapeInfo,
                                    void *extraParams,
                                    Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

    auto stream = lc->getCudaStream();
    dim3 launchDims(512, 512, 16384);

    auto xRank = shape::rank(hXShapeInfo);
    auto zRank = shape::rank(hZShapeInfo);
    auto xType = ArrayOptions::dataType(hXShapeInfo);
    auto zType = ArrayOptions::dataType(hZShapeInfo);

    if (xType != zType || !DataTypeUtils::isR(xType))
        throw datatype_exception::build("NativeOpExecutioner::execTransformStrict requires X & Z to have same floating point type", xType, zType);

    switch (opNum) {
        case transform::SoftMax:
        case transform::SoftMaxDerivative:
        case transform::LogSoftMax: {
                if (shape::isVector(hXShapeInfo)) {
                    int length = shape::length(hXShapeInfo);
                    int block = nd4j::math::nd4j_min<int>(length, 256);

                    launchDims.x = 1;
                    launchDims.y = block;
                    launchDims.z += (block * sizeof(double) * 4);

                    BUILD_SINGLE_SELECTOR(xType, functions::transform::TransformStrict, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, lc->getAllocationPointer(), lc->getReductionPointer(), nullptr, nullptr), FLOAT_TYPES);
                } else {
                    auto shape = shape::shapeOf(hXShapeInfo);
                    auto reductionPointer = lc->getReductionPointer();
					auto allocationPointer = lc->getAllocationPointer();
					auto specialPointer = reinterpret_cast<double *>(allocationPointer);

                    // special pointer for special buffer for special ops
                    auto dimension = reinterpret_cast<int *>(specialPointer);
                    auto maxDimension = dimension + 1;
                    auto maxShapeBuffer = reinterpret_cast<Nd4jLong *>(maxDimension + 1);
                    auto special = reinterpret_cast<double *> (maxShapeBuffer + (MAX_RANK * 2 + 4));


                    Nd4jLong maxShape[2] = {shape::shapeOf(hXShapeInfo)[0], 1};
                    auto hostMaxShapeBuffer = shape::shapeBuffer(2, xType, maxShape);

                    prepareShapeBuffer<<<1, 1, 128, *stream>>>(dimension, maxDimension, maxShapeBuffer, shape[0], xType);

                    DEBUG_KERNEL(stream, opNum);

                    // max 3
                    execReduceSame(lc, reduce::Max, hX, hXShapeInfo, dX, dXShapeInfo, extraParams, nullptr, hostMaxShapeBuffer, special, maxShapeBuffer, maxDimension, 1, tadShapeInfo, tadOffsets);

                    DEBUG_KERNEL(stream, opNum);

                    // sub 1
                    execBroadcast(lc, broadcast::Subtract, hX, hXShapeInfo, dX, dXShapeInfo, nullptr, hostMaxShapeBuffer, special, maxShapeBuffer, nullptr, hZShapeInfo, dZ, dZShapeInfo, dimension, 1, tadShapeInfo, tadOffsets, nullptr, nullptr);

                    DEBUG_KERNEL(stream, opNum);

                    // exp 3
                    execTransformFloat(lc, transform::Exp, hZ, hZShapeInfo, dZ, dZShapeInfo, hZ, hZShapeInfo, dZ, dZShapeInfo, extraParams, tadShapeInfo, tadOffsets);

                    DEBUG_KERNEL(stream, opNum);

                    //sum 1
                    execReduceSame(lc, reduce::Sum, hZ, hZShapeInfo, dZ, dZShapeInfo, extraParams, nullptr, hostMaxShapeBuffer, special, maxShapeBuffer, maxDimension, 1, tadShapeInfo, tadOffsets);

                    // divide 3
                    execBroadcast(lc, broadcast::Divide, hZ, hZShapeInfo, dZ, dZShapeInfo, nullptr, hostMaxShapeBuffer, special, maxShapeBuffer, nullptr, hZShapeInfo, dZ, dZShapeInfo, dimension, 1, tadShapeInfo, tadOffsets, nullptr, nullptr);

                    DEBUG_KERNEL(stream, opNum);

                    // log 3
                    if (opNum == transform::LogSoftMax)
                        execTransformFloat(lc, transform::Log, nullptr, hZShapeInfo, dZ, dZShapeInfo, nullptr, hZShapeInfo, dZ, dZShapeInfo, extraParams, tadShapeInfo, tadOffsets);
                    else if (opNum == transform::SoftMaxDerivative)
                        execTransformStrict(lc, transform::SpecialDerivative, nullptr, hZShapeInfo, dZ, dZShapeInfo, nullptr, hZShapeInfo, dZ, dZShapeInfo, extraParams, tadShapeInfo, tadOffsets);

                    nd4j::DebugHelper::checkErrorCode(stream, "SoftMax(...) failed");

                    delete hostMaxShapeBuffer;
                }
            }
            break;
        default: {
            BUILD_SINGLE_SELECTOR(xType, functions::transform::TransformStrict, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr), FLOAT_TYPES);
        }
    }
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execTransformFloat(nd4j::LaunchContext  *lc,
                                int opNum,
                                void *hX, Nd4jLong *hXShapeInfo,
                                void *dX, Nd4jLong *dXShapeInfo,
                                void *hZ, Nd4jLong *hZShapeInfo,
                                void *dZ, Nd4jLong *dZShapeInfo,
                                void *extraParams,
                                Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    auto xRank = shape::rank(hXShapeInfo);
    auto zRank = shape::rank(hZShapeInfo);
    auto xType = ArrayOptions::dataType(hXShapeInfo);
    auto zType = ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isR(zType))
        throw datatype_exception::build("NativeOpExecutioner::execTransformFloat requires Z to have floating point type", zType);

    if (opNum == transform::Histogram) {
        dim3 launchDims(256, 256, 32768);

        Nd4jPointer maskedallocationPointer;
        auto length = shape::length(hZShapeInfo);
        cudaMalloc(reinterpret_cast<void **>(&maskedallocationPointer), length * launchDims.x * DataTypeUtils::sizeOf(nd4j::DataType::INT64));
        auto imaskedallocationPointer = reinterpret_cast<int *>(maskedallocationPointer);

        BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformFloat, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, imaskedallocationPointer, reductionPointer, nullptr, nullptr), LIBND4J_TYPES, FLOAT_TYPES);

        checkCudaErrors(cudaStreamSynchronize(*stream));
        cudaFree(maskedallocationPointer);
    } else {
        dim3 launchDims(512, 512, 16384);
        BUILD_DOUBLE_SELECTOR(xType, zType, functions::transform::TransformFloat, ::executeTransformShaped(launchDims, stream, opNum, dX, dXShapeInfo, xRank, extraParams, dZ, dZShapeInfo, zRank, nullptr, nullptr, nullptr, nullptr), LIBND4J_TYPES, FLOAT_TYPES);
    }
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStats(nd4j::LaunchContext  *lc,
                                int opNum,
                                void *hX, Nd4jLong *hXShapeInfo,
                                void *dX, Nd4jLong *dXShapeInfo,
                                void *extraParams,
                                void *hZ, Nd4jLong *hZShapeInfo,
                                void *dZ, Nd4jLong *dZShapeInfo,
                                bool biasCorrected) {

    auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();

    dim3 launchDims = dim3(256, 256, 32768);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execSummaryStats requires Z operand to have floating point data type", zType);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::summarystats::SummaryStatsReduce, ::execSummaryStatsReduce(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ, dZShapeInfo, hZShapeInfo, nullptr, nullptr, biasCorrected, reductionPointer), LIBND4J_TYPES, FLOAT_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execSummaryStats(nd4j::LaunchContext  *lc,
                                			int opNum,
                                			void *hX, Nd4jLong *hXShapeInfo,
                                			void *dX, Nd4jLong *dXShapeInfo,
                                			void *extraParams,
                                			void *hZ, Nd4jLong *hZShapeInfo,
                                			void *dZ, Nd4jLong *dZShapeInfo,
                                			int *dimension, int dimensionLength,
                                            Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets,
                                			bool biasCorrected) {
	auto stream = lc->getCudaStream();
	auto reductionPointer = lc->getReductionPointer();

    dim3 launchDims = dim3(256, 256, 32768);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execSummaryStats requires Z operand to have floating point data type", zType);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::summarystats::SummaryStatsReduce, ::execSummaryStatsReduce(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, extraParams, dZ, dZShapeInfo, hZShapeInfo, dimension, dimensionLength, tadShapeInfo, tadOffsets, biasCorrected, reductionPointer), LIBND4J_TYPES, FLOAT_TYPES);
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *extraParams,
                            void *hY, Nd4jLong *hYShapeInfo,
                            void *dY, Nd4jLong *dYShapeInfo,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo) {

	auto stream = lc->getCudaStream();
    auto reductionPointer = lc->getReductionPointer();
	auto allocationPointer = lc->getAllocationPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(shape::length(hXShapeInfo), blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    if (xType != yType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Y operand to have X type", xType, yType);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Z operand to have floating point data type", zType);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3, ::execScalar(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ, dZShapeInfo, allocationPointer, reductionPointer, nullptr), LIBND4J_TYPES, FLOAT_TYPES);

    DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3(nd4j::LaunchContext  *lc,
                            int opNum,
                            void *hX, Nd4jLong *hXShapeInfo,
                            void *dX, Nd4jLong *dXShapeInfo,
                            void *extraParams,
                            void *hY, Nd4jLong *hYShapeInfo,
                            void *dY, Nd4jLong *dYShapeInfo,
                            void *hZ, Nd4jLong *hZShapeInfo,
                            void *dZ, Nd4jLong *dZShapeInfo,
                            int *dimension, int dimensionLength,
                            Nd4jLong* tadOnlyShapeInfo, Nd4jLong* tadOffsets,
                            Nd4jLong* yTadOnlyShapeInfo, Nd4jLong* yTadOffsets) {

    if(shape::isScalar(hZShapeInfo)) {
        NativeOpExecutioner::execReduce3(lc, opNum, hX, hXShapeInfo, dX, dXShapeInfo, extraParams, hY, hYShapeInfo, dY, dYShapeInfo, hZ, hZShapeInfo, dZ, dZShapeInfo);
        return;
    }

    auto stream = lc->getCudaStream();
    auto allocationPointer = lc->getAllocationPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

     if (xType != yType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Y operand to have X type", xType, yType);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3 requires Z operand to have floating point data type", zType);


    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3, ::exec(launchDims, stream, opNum,
                                                                    dX, dXShapeInfo,
                                                                    dY, dYShapeInfo,
                                                                    extraParams,
                                                                    dZ, dZShapeInfo,
                                                                    dimension, dimensionLength,
                                                                    1,
                                                                    allocationPointer,
                                                                    tadOnlyShapeInfo, tadOffsets,
                                                                    yTadOnlyShapeInfo, yTadOffsets), LIBND4J_TYPES, FLOAT_TYPES);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3Scalar(nd4j::LaunchContext  *lc,
								  int opNum,
                                  void *hX, Nd4jLong *hXShapeInfo,
                                  void *dX, Nd4jLong *dXShapeInfo,
                                  void *extraParams,
                                  void *hY, Nd4jLong *hYShapeInfo,
                                  void *dY, Nd4jLong *dYShapeInfo,
                                  void *hZ, Nd4jLong *hZShapeInfo,
                                  void *dZ, Nd4jLong *dZShapeInfo) {


	auto stream 		   = lc->getCudaStream();
	auto allocationPointer = lc->getAllocationPointer();
	auto reductionPointer  = lc->getReductionPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    auto xLength = shape::length(hXShapeInfo);
    auto blockWidth = 256;
    auto numBlocks = CudaLaunchHelper::getReductionBlocks(xLength, blockWidth);
    dim3 launchDims(numBlocks, blockWidth, 32768);

    if (xType != yType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3Scalar requires Y operand to have X type", xType, yType);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3Scalar requires Z operand to have floating point data type", zType);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3, ::execScalar(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ, dZShapeInfo, allocationPointer, reductionPointer, nullptr), LIBND4J_TYPES, FLOAT_TYPES);
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarBool(nd4j::LaunchContext  *lc,
										int opNum,
										void *hX, Nd4jLong *hXShapeInfo,
										void *dX, Nd4jLong *dXShapeInfo,
										void *hZ, Nd4jLong *hZShapeInfo,
										void *dZ, Nd4jLong *dZShapeInfo,
										void *hScalar, Nd4jLong *hScalarShapeInfo,
										void *dScalar, Nd4jLong *dScalarShapeInfo,
										void *extraParams) {

	auto stream = lc->getCudaStream();

	dim3 launchDims = dim3(256, 512, 8192);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto yType = nd4j::ArrayOptions::dataType(hScalarShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

	if (xType != yType )
		throw std::runtime_error("NativeOpExecutioner::execScalarBool requires X & Y to have same type");

	if (!DataTypeUtils::isB(zType) )
		throw std::runtime_error("NativeOpExecutioner::execScalarBool requires Z operand to have BOOL type");

	BUILD_DOUBLE_SELECTOR(xType, zType, functions::scalar::ScalarBoolTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalar, extraParams), LIBND4J_TYPES, BOOL_TYPES);

	DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalarBool(nd4j::LaunchContext  *lc,
						   				int opNum,
						   				void *hX, Nd4jLong *hXShapeInfo,
						   				void *dX, Nd4jLong *dXShapeInfo,
                                        void *extraParams,
						   				void *hZ, Nd4jLong *hZShapeInfo,
						   				void *dZ, Nd4jLong *dZShapeInfo,
						   				void *hScalars, Nd4jLong *hScalarShapeInfo,
						   				void *dScalars, Nd4jLong *dScalarShapeInfo,
						   				int *dimension, int dimensionLength,
                           				Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets,
                           				Nd4jLong *tadShapeInfoZ, Nd4jLong *tadOffsetsZ) {

	auto stream = lc->getCudaStream();

	dim3 launchDims(256, 512, 8192);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto yType = nd4j::ArrayOptions::dataType(hScalarShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

	if (xType != yType )
		throw std::runtime_error("NativeOpExecutioner::execScalarBool requires X & Y to have same type");

	if (!DataTypeUtils::isB(zType) )
		throw std::runtime_error("NativeOpExecutioner::execScalarBool requires Z operand to have BOOL type");

	BUILD_DOUBLE_SELECTOR(xType, zType, functions::scalar::ScalarBoolTransform, ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams, dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, BOOL_TYPES);

	DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalar(nd4j::LaunchContext  *lc,
									int opNum,
									void *hX, Nd4jLong *hXShapeInfo,
									void *dX, Nd4jLong *dXShapeInfo,
									void *hZ, Nd4jLong *hZShapeInfo,
									void *dZ, Nd4jLong *dZShapeInfo,
									void *hScalar, Nd4jLong *hScalarShapeInfo,
									void *dScalar, Nd4jLong *dScalarShapeInfo,
									void *extraParams) {

	auto stream = lc->getCudaStream();

	dim3 launchDims(256, 512, 8192);

	auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
	auto yType = nd4j::ArrayOptions::dataType(hScalarShapeInfo);
	auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);


#ifdef __ND4J_EXPERIMENTAL__
	BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::scalar::ScalarTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, dZ, dZShapeInfo, hZShapeInfo, dScalar, extraParams), LIBND4J_TYPES, LIBND4J_TYPES);
#else
	BUILD_SINGLE_SELECTOR_THRICE(xType, functions::scalar::ScalarTransform, ::executeCudaShaped(launchDims, stream, opNum, dX, dXShapeInfo, hXShapeInfo, dZ, dZShapeInfo, hZShapeInfo, dScalar, extraParams), LIBND4J_TYPES);
#endif

	DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execScalar(nd4j::LaunchContext  *lc,
					 				int opNum,
					 				void *hX, Nd4jLong *hXShapeInfo,
                     				void *dX, Nd4jLong *dXShapeInfo,
                                    void *extraParams,
                     				void *hZ, Nd4jLong *hZShapeInfo,
                     				void *dZ, Nd4jLong *dZShapeInfo,
                     				void *hScalars, Nd4jLong *hScalarShapeInfo,
                     				void *dScalars, Nd4jLong *dScalarShapeInfo,
					 				int *dimension, int dimensionLength,
                     				Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets,
                     				Nd4jLong *tadShapeInfoZ, Nd4jLong *tadOffsetsZ) {

    auto stream = lc->getCudaStream();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hScalarShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

	dim3 launchDims(256, 256, 16384);

#ifdef __ND4J_EXPERIMENTAL__
    BUILD_PAIRWISE_SELECTOR(xType, yType, zType, functions::scalar::ScalarTransform, ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams, dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES, LIBND4J_TYPES);
#else
	BUILD_SINGLE_SELECTOR_THRICE(xType, functions::scalar::ScalarTransform, ::executeCudaAlongDimension(launchDims, stream, opNum, dX, dXShapeInfo, dZ, dZShapeInfo, dScalars, extraParams, dimension, dimensionLength, tadShapeInfo, tadOffsets, tadShapeInfoZ, tadOffsetsZ), LIBND4J_TYPES);
#endif

	DEBUG_KERNEL(stream, opNum);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(nd4j::LaunchContext  *lc,
						  int opNum,
                          Nd4jPointer stateHost,
                          void *hZ, Nd4jLong *hZShapeInfo,
                          void *dZ, Nd4jLong *dZShapeInfo,
                          void *extraArguments) {

    auto stream = lc->getCudaStream();
    auto sizeOf = sizeof(nd4j::graph::RandomGenerator);
    Nd4jPointer stateDevice;

    cudaError_t res = cudaMalloc(reinterpret_cast<void **>(&stateDevice), sizeOf);
    checkCudaErrors(cudaStreamSynchronize(*stream));
    checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

    dim3 launchDims = dim3(512, 512, 32768);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    // functions::random::RandomFunction<float>::executeCudaSingle(launchDims, extraPointers, opNum, stateHost, dZ, dZShapeInfo, extraArguments),
    BUILD_SINGLE_SELECTOR(zType, functions::random::RandomFunction, ::executeCudaSingle(launchDims, stream, opNum, stateDevice, dZ, dZShapeInfo, extraArguments), FLOAT_TYPES);

    checkCudaErrors(cudaMemcpyAsync(stateHost, stateDevice, sizeOf, cudaMemcpyDeviceToHost, *stream));
    checkCudaErrors(cudaStreamSynchronize(*stream));
    cudaFree(stateDevice);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(nd4j::LaunchContext  *lc,
							int opNum,
							Nd4jPointer stateHost,
						   	void *hX, Nd4jLong *hXShapeInfo,
						   	void *dX, Nd4jLong *dXShapeInfo,
						   	void *hZ, Nd4jLong *hZShapeInfo,
						   	void *dZ, Nd4jLong *dZShapeInfo,
						   	void *extraArguments) {

    auto stream = lc->getCudaStream();

    auto sizeOf = sizeof(nd4j::graph::RandomGenerator);
    Nd4jPointer stateDevice;

    cudaError_t res = cudaMalloc(reinterpret_cast<void **>(&stateDevice), sizeOf);
    checkCudaErrors(cudaStreamSynchronize(*stream));
    checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

    dim3 launchDims = dim3(512, 512, 32768);
    auto xType = nd4j::ArrayOptions::dataType(hZShapeInfo);
    // functions::random::RandomFunction<float>::executeCudaDouble(launchDims, extraPointers, opNum, stateHost, dX, dXShapeInfo, dZ, dZShapeInfo, extraArguments);
    BUILD_SINGLE_SELECTOR(xType, functions::random::RandomFunction, ::executeCudaDouble(launchDims, stream, opNum, stateDevice, dX, dXShapeInfo, dZ, dZShapeInfo, extraArguments), FLOAT_TYPES);

    checkCudaErrors(cudaMemcpyAsync(stateHost, stateDevice, sizeOf, cudaMemcpyDeviceToHost, *stream));
    checkCudaErrors(cudaStreamSynchronize(*stream));
    cudaFree(stateDevice);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execRandom(nd4j::LaunchContext  *lc,
							int opNum,
							Nd4jPointer stateHost,
							void *hX, Nd4jLong *hXShapeInfo,
							void *dX, Nd4jLong *dXShapeInfo,
							void *hY, Nd4jLong *hYShapeInfo,
							void *dY, Nd4jLong *dYShapeInfo,
							void *hZ, Nd4jLong *hZShapeInfo,
							void *dZ, Nd4jLong *dZShapeInfo,
							void *extraArguments) {

    auto stream = lc->getCudaStream();
    auto sizeOf = sizeof(nd4j::graph::RandomGenerator);
    Nd4jPointer stateDevice;

    cudaError_t res = cudaMalloc(reinterpret_cast<void **>(&stateDevice), sizeOf);
    checkCudaErrors(cudaStreamSynchronize(*stream));
    checkCudaErrors(cudaMemcpyAsync(stateDevice, stateHost, sizeOf, cudaMemcpyHostToDevice, *stream));

    dim3 launchDims = dim3(512, 512, 32768);
    auto xType = nd4j::ArrayOptions::dataType(hZShapeInfo);
    // functions::random::RandomFunction<float>::executeCudaTriple(launchDims, extraPointers, opNum, stateHost, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraArguments);
    BUILD_SINGLE_SELECTOR(xType, functions::random::RandomFunction, ::executeCudaTriple(launchDims, stream, opNum, stateDevice, dX, dXShapeInfo, dY, dYShapeInfo, dZ, dZShapeInfo, extraArguments), FLOAT_TYPES);

    checkCudaErrors(cudaMemcpyAsync(stateHost, stateDevice, sizeOf, cudaMemcpyDeviceToHost, *stream));
    checkCudaErrors(cudaStreamSynchronize(*stream));
    cudaFree(stateDevice);
}

////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3All(nd4j::LaunchContext  *lc,
									int opNum,
									void *hX, Nd4jLong *hXShapeInfo,
                            		void *dX, Nd4jLong *dXShapeInfo,
                            		void *extraParamsVals,
									void *hY, Nd4jLong *hYShapeInfo,
                            		void *dY, Nd4jLong *dYShapeInfo,
                            		void *hZ, Nd4jLong *hZShapeInfo,
                            		void *dZ, Nd4jLong *dZShapeInfo,
									int *dimension, int dimensionLength,
									Nd4jLong *xTadShapeInfo, Nd4jLong *xOffsets,
									Nd4jLong *yTadShapeInfo, Nd4jLong *yOffsets) {

    auto stream = lc->getCudaStream();
    auto allocationPointer = lc->getAllocationPointer();
	auto reductionPointer  = lc->getReductionPointer();

    if (nd4j::Environment::getInstance()->isDebugAndVerbose())
        printf("D119 opNum:[%i]\n", opNum);

    dim3 launchDims(shape::length(hZShapeInfo), 256, 32768);

    if (nd4j::Environment::getInstance()->isVerbose() && launchDims.x == 1)
        printf("AD119 opNum:[%i]\n", opNum);

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

    if (yType != xType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3All both operands must have same data type", xType, yType);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3, ::execAll(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParamsVals, dZ, dZShapeInfo, dimension, dimensionLength, 1, allocationPointer, xTadShapeInfo, xOffsets, yTadShapeInfo, yOffsets), LIBND4J_TYPES, FLOAT_TYPES);

	DEBUG_KERNEL(stream, opNum);
}


////////////////////////////////////////////////////////////////////////
void NativeOpExecutioner::execReduce3TAD(nd4j::LaunchContext  *lc,
                                            int opNum,
                                            void *hX, Nd4jLong *hXShapeInfo,
                                            void *dX, Nd4jLong *dXShapeInfo,
                                            void *extraParams,
                                            void *hY, Nd4jLong *hYShapeInfo,
                                            void *dY, Nd4jLong *dYShapeInfo,
                                            void *hZ, Nd4jLong *hZShapeInfo,
                                            void *dZ, Nd4jLong *dZShapeInfo,
                                            int *dimension, int dimensionLength,
                                            Nd4jLong *tadShapeInfo, Nd4jLong *tadOffsets,
                                            Nd4jLong *yTadShapeInfo, Nd4jLong *yTadOffsets) {

    if(shape::isScalar(hZShapeInfo)) {
        NativeOpExecutioner::execReduce3(lc, opNum, hX, hXShapeInfo, dX, dXShapeInfo, extraParams, hY, hYShapeInfo, dY, dYShapeInfo, hZ, hZShapeInfo, dZ, dZShapeInfo);
        return;
    }

    auto stream = lc->getCudaStream();
    auto allocationPointer = lc->getAllocationPointer();

    auto xType = nd4j::ArrayOptions::dataType(hXShapeInfo);
    auto yType = nd4j::ArrayOptions::dataType(hYShapeInfo);
    auto zType = nd4j::ArrayOptions::dataType(hZShapeInfo);

     if (xType != yType)
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3TAD requires Y operand to have X type", xType, yType);

    if (!DataTypeUtils::isR(zType))
        throw nd4j::datatype_exception::build("NativeOpExecutioner::execReduce3TAD requires Z operand to have floating point data type", zType);

    auto numBlocks = shape::length(hZShapeInfo);
    dim3 launchDims(numBlocks, 256, 32768);

    BUILD_DOUBLE_SELECTOR(xType, zType, functions::reduce3::Reduce3, ::exec(launchDims, stream, opNum, dX, dXShapeInfo, dY, dYShapeInfo, extraParams, dZ, dZShapeInfo, dimension, dimensionLength, 1, allocationPointer, tadShapeInfo, tadOffsets, yTadShapeInfo, yTadOffsets), LIBND4J_TYPES, FLOAT_TYPES);
}

